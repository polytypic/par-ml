[@@@alert "-unstable"]

open Util

let mutex = Mutex.create ()
let condition = Condition.create ()
let result_ready = Multicore.copy_as_padded (ref false)

type 'a continuation = ('a, unit) Effect.Deep.continuation
type _ Effect.t += Suspend : ('a continuation -> unit) -> 'a Effect.t

let effc (type a) : a Effect.t -> _ = function
  | Suspend ef -> Some ef
  | _ -> None

let handler =
  Multicore.copy_as_padded {Effect.Deep.retc = ignore; exnc = raise; effc}

type 'a fiber_state =
  | Initial of (unit -> 'a)
  | Join of 'a continuation * 'a fiber_state
  | Running
  | Return of 'a
  | Raise of exn

type work = Work : 'a fiber_state Atomic.t -> work

let num_waiters_non_zero = Multicore.copy_as_padded (ref false)
let num_waiters = Multicore.copy_as_padded (ref 0)

let workers =
  Multicore.make_padded_array (Domain.recommended_domain_count ()) (null ())

let rec dispatch res = function
  | Join (k, ws) ->
    begin
      match res with
      | Return x -> Effect.Deep.continue k x
      | Raise e -> Effect.Deep.discontinue k e
      | _ -> impossible ()
    end;
    dispatch res ws
  | _ -> res

let run_fiber st th =
  let res = match th () with x -> Return x | exception e -> Raise e in
  dispatch res (Atomic.exchange st res)

let run_work (Work st) =
  match Atomic.get st with
  | Initial th as was ->
    if Atomic.compare_and_set st was Running then run_fiber st th |> ignore
  | _ -> ()

let rec loop dcyl =
  let work = DCYL.pop dcyl in
  Effect.Deep.match_with run_work work handler;
  loop dcyl

let rec main wr =
  try loop wr with DCYL.Empty -> try_steal wr ((Domain.self () :> int) + 1)

and try_steal wr i =
  let victim = Array.unsafe_get workers i in
  if victim == null () then try_steal wr 0
  else if victim == wr then wait wr i
  else
    match DCYL.steal victim with
    | work ->
      Effect.Deep.match_with run_work work handler;
      main wr
    | exception DCYL.Empty -> try_steal wr (i + 1)

and wait wr i =
  if not !result_ready then begin
    Mutex.lock mutex;
    let n = !num_waiters + 1 in
    num_waiters := n;
    if n = 1 then num_waiters_non_zero := true;
    if not !result_ready then Condition.wait condition mutex;
    let n = !num_waiters - 1 in
    num_waiters := n;
    if n = 0 then num_waiters_non_zero := false;
    Mutex.unlock mutex;
    try_steal wr (i + 1)
  end

let worker () = workers.((Domain.self () :> int)) [@@inline]

let push wr work =
  DCYL.push wr work;
  if !num_waiters_non_zero then Condition.signal condition
  [@@inline]

(* *)

let run ?num_workers ef =
  if 0 <> (Domain.self () :> int) then failwith "only main domain may call run";
  if !result_ready then failwith "run can only be called once";
  let max_workers = Multicore.length_of_padded_array workers in
  let num_workers =
    num_workers
    |> Option.map (Int.max 1)
    |> Option.map (Int.min max_workers)
    |> Option.value ~default:max_workers
  in
  for i = 0 to num_workers - 1 do
    Array.unsafe_set workers i (DCYL.make ())
  done;
  let domains =
    Array.init (num_workers - 1) @@ fun _ ->
    Domain.spawn @@ fun () ->
    let i = (Domain.self () :> int) in
    if num_workers <= i then failwith "add_worker: not sequential";
    let wr = Array.unsafe_get workers i in
    main wr
  in
  let result = ref (null ()) in
  Effect.Deep.match_with
    (fun ef ->
      (result := match ef () with v -> Ok v | exception e -> Error e);
      Mutex.lock mutex;
      result_ready := true;
      Condition.broadcast condition;
      Mutex.unlock mutex)
    ef handler;
  main (Array.unsafe_get workers 0);
  Array.iter Domain.join domains;
  Result.run !result

module Continuation = struct
  type 'a t = 'a continuation

  let suspend ef = Effect.perform (Suspend ef) [@@inline]
  let return k v = Effect.Deep.continue k v [@@inline]
  let raise k e = Effect.Deep.discontinue k e [@@inline]
end

let par tha thb =
  let wr = worker () in
  let i = DCYL.mark wr in
  let st = Atomic.make @@ Initial tha in
  push wr (Work st);
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

module Fiber = struct
  type 'a t = work DCYL.t * DCYL.pos * 'a fiber_state Atomic.t

  let spawn th =
    let wr = worker () in
    let i = DCYL.mark wr in
    let st = Atomic.make @@ Initial th in
    let fiber = (wr, i, st) in
    push wr (Work st);
    fiber

  let rec join ((wr', i, st) as fiber) =
    match Atomic.get st with
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
          match Atomic.get st with
          | Return x -> Continuation.return k x
          | Raise e -> Continuation.raise k e
          | was -> loop was
      in
      loop was
end
