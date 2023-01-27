[@@@alert "-unstable"]

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

let handler = Multicore_magic.copy_as_padded {Effect.Deep.effc}

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
  | Return of 'a
  | Raise of exn

and worker = work DCYL.t
and work = W : 'a st Atomic.t -> work

(* *)

let num_waiters_non_zero = Multicore_magic.copy_as_padded (ref false)
let num_waiters = Multicore_magic.copy_as_padded (ref 0)

let workers =
  let num_workers =
    (try int_of_string_opt Sys.argv.(1) with _ -> None)
    |> Option.map (Int.max 1)
    |> Option.map (Int.min (Domain.recommended_domain_count ()))
    |> Option.value ~default:(Domain.recommended_domain_count ())
  in
  Multicore_magic.copy_as_padded
    (Array.init num_workers (fun _ -> DCYL.create ()))

let rec dispatch res = function
  | Join (k, ws) ->
    begin
      match res with
      | Return x -> Continuation.return k x
      | Raise e -> Continuation.raise k e
      | _ -> impossible ()
    end;
    dispatch res ws
  | _ -> res

let run_fiber st th =
  let res = match th () with x -> Return x | exception e -> Raise e in
  dispatch res (Atomic.exchange st res)

let doit (W st) =
  match Multicore_magic.fenceless_get st with
  | Initial th as was ->
    if Atomic.compare_and_set st was Running then run_fiber st th |> ignore
  | _ -> ()

let rec loop dcyl =
  let work = DCYL.pop dcyl in
  Effect.Deep.try_with doit work handler;
  loop dcyl

let next_index i =
  let i = i + 1 in
  if i < Multicore_magic.length_of_padded_array workers then i else 0
  [@@inline]

let first_index () = next_index (Domain.self () :> int) [@@inline]

let rec main wr = try loop wr with Exit -> try_steal wr (first_index ())

and try_steal wr i =
  let victim = Array.unsafe_get workers i in
  if victim == wr then wait wr i
  else
    match DCYL.steal victim with
    | work ->
      (*if DCYL.seems_non_empty victim then Condition.signal condition;*)
      Effect.Deep.try_with doit work handler;
      main wr
    | exception Exit -> try_steal wr (next_index i)

and wait wr i =
  if i <> 0 then begin
    Mutex.lock mutex;
    let n = !num_waiters + 1 in
    num_waiters := n;
    if n = 1 then num_waiters_non_zero := true;
    Condition.wait condition mutex;
    let n = !num_waiters - 1 in
    num_waiters := n;
    if n = 0 then num_waiters_non_zero := false;
    Mutex.unlock mutex;
    try_steal wr (next_index i)
  end

let () =
  for _ = 2 to Multicore_magic.length_of_padded_array workers do
    Domain.spawn (fun () ->
        let i = (Domain.self () :> int) in
        if Multicore_magic.length_of_padded_array workers <= i then
          failwith "add_worker: not sequential";
        let wr = Array.unsafe_get workers i in
        main wr)
    |> ignore
  done

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
      match ef () with v -> res := Ok v | exception e -> res := Error e)
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
    | Return x -> (x, y)
    | Raise e -> raise e
    | Initial tha ->
      DCYL.drop_at wr i;
      (tha (), y)
    | _running ->
      ( Continuation.suspend (fun k ->
            match Atomic.exchange st (Join (k, Running)) with
            | Return x -> Continuation.return k x
            | Raise e -> Continuation.raise k e
            | _ -> ()),
        y )
  end
  | exception e ->
    let _ =
      match Atomic.exchange st Running with
      | Return _ -> null ()
      | Raise e -> raise e
      | Initial _ -> DCYL.drop_at wr i |> null
      | _running ->
        Continuation.suspend (fun k ->
            match Atomic.exchange st (Join (k, Running)) with
            | Return _ -> Continuation.return k (null ())
            | Raise e -> Continuation.raise k e
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
    match Multicore_magic.fenceless_get st with
    | Initial th as t ->
      if Atomic.compare_and_set st t Running then begin
        let wr = worker () in
        if wr == wr' then DCYL.drop_at wr i;
        match run_fiber st th with
        | Return x -> x
        | Raise e -> raise e
        | _ -> impossible ()
      end
      else join fiber
    | Return x -> x
    | Raise e -> raise e
    | was ->
      Continuation.suspend @@ fun k ->
      let rec loop was =
        if not (Atomic.compare_and_set st was (Join (k, was))) then
          match Multicore_magic.fenceless_get st with
          | Return x -> Continuation.return k x
          | Raise e -> Continuation.raise k e
          | was -> loop was
      in
      loop was
end
