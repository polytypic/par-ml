[@@@alert "-unstable"]
[@@@ocaml.warning "-69"] (* Disable unused field warning. *)

let null _ = Obj.magic () [@@inline]
let impossible () = failwith "impossible"

(* *)

let mutex = Mutex.create ()
let condition = Condition.create ()

(* *)

type 'a continuation = ('a, unit) Effect.Deep.continuation
type _ Effect.t += Suspend : ('a continuation -> unit) -> 'a Effect.t

let effc (type a) : a Effect.t -> _ = function
  | Suspend ef -> Some ef
  | _ -> None

let handler = Multicore.copy_as_padded {Effect.Deep.effc}

(* *)

module Continuation = struct
  type 'a t = 'a continuation

  let suspend ef = Effect.perform (Suspend ef) [@@inline]
  let return k v = Effect.Deep.continue k v [@@inline]
  let raise k e = Effect.Deep.discontinue k e [@@inline]
end

(* *)

type 'a st =
  | Initial of (unit -> 'a)
  | Join of 'a Continuation.t * 'a st
  | Running
  | Ok of 'a
  | Error of exn

and worker = work DCYL.t
and work = W : 'a st Atomic.t -> work

(* *)

let num_waiters_non_zero = Multicore.copy_as_padded (ref false)
let num_waiters = Multicore.copy_as_padded (ref 0)

let num_workers =
  Sys.argv
  |> Array.find_map (fun arg ->
         let prefix = "--num-workers=" in
         if String.starts_with ~prefix arg then
           let n = String.length prefix in
           String.sub arg n (String.length arg - n) |> int_of_string_opt
         else None)
  |> Option.map (Int.max 1)
  |> Option.map (Int.min (Domain.recommended_domain_count ()))
  |> Option.value ~default:(Domain.recommended_domain_count ())

let workers =
  Multicore.copy_as_padded (Array.init num_workers (fun _ -> DCYL.make ()))

let rec dispatch res = function
  | Join (k, ws) ->
    begin
      match res with
      | Ok x -> Continuation.return k x
      | Error e -> Continuation.raise k e
      | _ -> impossible ()
    end;
    dispatch res ws
  | _ -> res

let run_fiber st th =
  let res = match th () with x -> Ok x | exception e -> Error e in
  dispatch res (Atomic.exchange st res)

let doit (W st) =
  match Atomic.get st with
  | Initial th as was ->
    if Atomic.compare_and_set st was Running then run_fiber st th |> ignore
  | _ -> ()

let rec loop dcyl =
  let work = DCYL.pop dcyl in
  Effect.Deep.try_with doit work handler;
  loop dcyl

let next_index i =
  let i = i + 1 in
  if i < num_workers then i else 0
  [@@inline]

let first_index () = next_index (Domain.self () :> int) [@@inline]

let add_waiter () =
  let n = !num_waiters + 1 in
  num_waiters := n;
  if n = 1 then num_waiters_non_zero := true;
  Condition.wait condition mutex;
  let n = !num_waiters - 1 in
  num_waiters := n;
  if n = 0 then num_waiters_non_zero := false

let rec main wr = try loop wr with DCYL.Empty -> try_steal wr (first_index ())

and try_steal wr i =
  let victim = Array.unsafe_get workers i in
  if victim == wr then wait wr i
  else
    match DCYL.steal victim with
    | work ->
      Effect.Deep.try_with doit work handler;
      main wr
    | exception DCYL.Empty -> try_steal wr (next_index i)

and wait wr i =
  if i <> 0 then begin
    Mutex.lock mutex;
    add_waiter ();
    Mutex.unlock mutex;
    try_steal wr (next_index i)
  end

let () =
  let num_workers' = ref 0 in

  let add_worker () =
    let i = (Domain.self () :> int) in
    if num_workers <= i then failwith "add_worker: not sequential";
    let wr = DCYL.make () in
    Mutex.lock mutex;
    Array.unsafe_set workers i wr;
    incr num_workers';
    if !num_workers' = num_workers then Condition.broadcast condition;
    Mutex.unlock mutex;
    wr
  in

  let wait_ready () =
    Mutex.lock mutex;
    while !num_workers' <> num_workers do
      Condition.wait condition mutex
    done;
    Mutex.unlock mutex
  in

  add_worker () |> ignore;
  for _ = 2 to num_workers do
    Domain.spawn (fun () ->
        let wr = add_worker () in
        wait_ready ();
        main wr)
    |> ignore
  done;

  wait_ready ()

let worker () = workers.((Domain.self () :> int)) [@@inline]

let push wr work =
  DCYL.push wr work;
  if !num_waiters_non_zero then Condition.signal condition
  [@@inline]

(* *)

let run ef =
  if 0 <> (Domain.self () :> int) then failwith "only main domain may call run";
  let res = ref (null ()) in
  Effect.Deep.try_with
    (fun ef ->
      match ef () with v -> res := Result.Ok v | exception e -> res := Error e)
    ef handler;
  while !res == null () do
    main (Array.unsafe_get workers 0)
  done;
  Result.run !res

(* *)

let par tha thb =
  let wr = worker () in
  let i = DCYL.mark wr in
  let st = Atomic.make @@ Initial tha in
  push wr (W st);
  match thb () with
  | y -> begin
    match Atomic.exchange st Running with
    | Ok x -> (x, y)
    | Error e -> raise e
    | Initial tha ->
      DCYL.drop_at wr i;
      (tha (), y)
    | _running ->
      ( Continuation.suspend (fun k ->
            match Atomic.exchange st (Join (k, Running)) with
            | Ok x -> Continuation.return k x
            | Error e -> Continuation.raise k e
            | _ -> ()),
        y )
  end
  | exception e ->
    let _ =
      match Atomic.exchange st Running with
      | Ok _ -> null ()
      | Error e -> raise e
      | Initial _ -> DCYL.drop_at wr i |> null
      | _running ->
        Continuation.suspend (fun k ->
            match Atomic.exchange st (Join (k, Running)) with
            | Ok _ -> Continuation.return k (null ())
            | Error e -> Continuation.raise k e
            | _ -> ())
    in
    raise e

(* *)

module Fiber = struct
  type 'a t = worker * DCYL.pos * 'a st Atomic.t

  let spawn th =
    let wr = worker () in
    let i = DCYL.mark wr in
    let st = Atomic.make @@ Initial th in
    let fiber = (wr, i, st) in
    push wr (W st);
    fiber

  let rec join ((wr', i, st) as fiber) =
    match Atomic.get st with
    | Initial th as t ->
      if Atomic.compare_and_set st t Running then begin
        let wr = worker () in
        if wr == wr' then DCYL.drop_at wr i;
        match run_fiber st th with
        | Ok x -> x
        | Error e -> raise e
        | _ -> impossible ()
      end
      else join fiber
    | Ok x -> x
    | Error e -> raise e
    | was ->
      Continuation.suspend @@ fun k ->
      let rec loop was =
        if not (Atomic.compare_and_set st was (Join (k, was))) then
          match Atomic.get st with
          | Ok x -> Continuation.return k x
          | Error e -> Continuation.raise k e
          | was -> loop was
      in
      loop was
end
