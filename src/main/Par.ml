[@@@alert "-unstable"]

let null _ = Obj.magic () [@@inline]
let impossible () = failwith "impossible"

(* *)

type 'a continuation = ('a, unit) Effect.Deep.continuation
type _ Effect.t += Suspend : ('a continuation -> unit) -> 'a Effect.t

let effc (type a) : a Effect.t -> _ = function
  | Suspend ef -> Some ef
  | _ -> None

let handler = {Effect.Deep.effc}

(* *)

let mutex = Mutex.create ()
let condition = Condition.create ()
let num_waiters = ref 0 (* TODO: this is non-scalable *)

type worker = (unit -> unit) DCYL.t

let num_workers =
  Sys.argv
  |> Array.find_map (fun arg ->
         let prefix = "--num-workers=" in
         if String.starts_with ~prefix arg then
           let n = String.length prefix in
           String.sub arg n (String.length arg - n) |> int_of_string_opt
         else None)
  |> Option.value ~default:(Domain.recommended_domain_count ())

let workers = Array.init num_workers (fun _ -> null ())

let rec loop dcyl =
  let work = DCYL.pop dcyl in
  Effect.Deep.try_with work () handler;
  loop dcyl

let rec main wr = try loop wr with DCYL.Empty -> try_steal wr

and try_steal wr =
  try_steal_loop wr (((Domain.self () :> int) + 1) mod num_workers)

and try_steal_loop wr i =
  let victim = workers.(i) in
  if victim == wr then wait wr
  else
    match DCYL.steal victim with
    | work ->
      Effect.Deep.try_with work () handler;
      main wr
    | exception DCYL.Empty -> try_steal_loop wr ((i + 1) mod num_workers)

and wait wr =
  if wr != workers.(0) then begin
    Mutex.lock mutex;
    incr num_waiters;
    Condition.wait condition mutex;
    decr num_waiters;
    Mutex.unlock mutex;
    try_steal wr
  end

let () =
  let num_workers' = ref 0 in

  let add_worker () =
    let i = (Domain.self () :> int) in
    if Array.length workers <= i then failwith "add_worker: not sequential";
    let wr = DCYL.make () in
    Mutex.lock mutex;
    Array.unsafe_set workers i wr;
    incr num_workers';
    Condition.broadcast condition;
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
  if !num_waiters <> 0 then Condition.signal condition
  [@@inline]

(* *)

module Continuation = struct
  type 'a t = 'a continuation

  let suspend ef = Effect.perform (Suspend ef) [@@inline]
  let return k v = Effect.Deep.continue k v [@@inline]
  let raise k e = Effect.Deep.discontinue k e [@@inline]
end

(* *)

let run ef =
  let res = Atomic.make (null ()) in
  let wr = worker () in
  push wr (fun () ->
      Atomic.set res (match ef () with v -> Ok v | exception e -> Error e));
  while Atomic.get res == null () do
    main wr
  done;
  Atomic.get res |> Result.run

(* *)

let par tha thb =
  let open struct
    type 'a par =
      | Initial of (unit -> 'a)
      | Running
      | Join of 'a Continuation.t
      | Ok of 'a
      | Error of exn
  end in
  let st = Atomic.make @@ Initial tha in
  let work () =
    match Atomic.exchange st Running with
    | Initial tha -> begin
      match tha () with
      | x -> begin
        match Atomic.exchange st (Ok x) with
        | Join k -> Continuation.return k x
        | _ -> ()
      end
      | exception e -> begin
        match Atomic.exchange st (Error e) with
        | Join k -> Continuation.raise k e
        | _ -> ()
      end
    end
    | _ -> ()
  in
  let wr = worker () in
  let i = DCYL.mark wr in
  push wr work;
  match thb () with
  | y -> begin
    match Atomic.exchange st Running with
    | Ok x -> (x, y)
    | Error e -> raise e
    | Initial tha ->
      DCYL.drop_at wr i |> ignore;
      (tha (), y)
    | _running ->
      ( Continuation.suspend (fun k ->
            match Atomic.exchange st (Join k) with
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
            match Atomic.exchange st (Join k) with
            | Ok _ -> Continuation.return k (null ())
            | Error e -> Continuation.raise k e
            | _ -> ())
    in
    raise e

(* *)

module Fiber = struct
  type 'a st =
    | Initial of (unit -> 'a) * worker * DCYL.pos
    | Running
    | Join of 'a Continuation.t * 'a st
    | Ok of 'a
    | Error of exn

  type 'a t = 'a st Atomic.t

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

  let run st th =
    let res = match th () with x -> Ok x | exception e -> Error e in
    dispatch res (Atomic.exchange st res)

  let spawn th =
    let wr = worker () in
    let st = Atomic.make @@ Initial (th, wr, DCYL.mark wr) in
    let work () =
      match Atomic.get st with
      | Initial (th, _, _) as t ->
        if Atomic.compare_and_set st t Running then run st th |> ignore
      | _ -> ()
    in
    push wr work;
    st

  let rec join st =
    match Atomic.get st with
    | Initial (th, wr', i) as t ->
      if Atomic.compare_and_set st t Running then begin
        let wr = worker () in
        if wr == wr' then DCYL.drop_at wr i |> ignore;
        match run st th with
        | Ok x -> x
        | Error e -> raise e
        | _ -> impossible ()
      end
      else join st
    | Ok x -> x
    | Error e -> raise e
    | (Running | Join _) as w ->
      Continuation.suspend @@ fun k ->
      let rec loop w =
        if not (Atomic.compare_and_set st w (Join (k, w))) then
          match Atomic.get st with
          | Ok x -> Continuation.return k x
          | Error e -> Continuation.raise k e
          | was -> loop was
      in
      loop w
end
