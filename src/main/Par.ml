[@@@alert "-unstable"]

open Util

let mutex = Mutex.create ()

type 'a continuation = ('a, unit) Effect.Deep.continuation
type _ Effect.t += Suspend : ('a continuation -> unit) -> 'a Effect.t

let effc (type a) : a Effect.t -> _ = function
  | Suspend ef -> Some ef
  | _ -> None

let handler =
  Multicore_magic.copy_as_padded {Effect.Deep.retc = ignore; exnc = raise; effc}

type 'a fiber_state =
  | Initial of (unit -> 'a)
  | Join of 'a continuation * 'a fiber_state
  | Running
  | Return of 'a
  | Raise of exn

type work = Work : 'a fiber_state Atomic.t -> work

let workers =
  Multicore_magic.copy_as_padded
    (ref
       (Multicore_magic.make_padded_array
          (Domain.recommended_domain_count ())
          (null ())))

let worker_at i = Array.unsafe_get !workers i [@@inline]
let worker () = worker_at (Domain.self () :> int) [@@inline]

let set ar i x =
  let n = Multicore_magic.length_of_padded_array !ar in
  if n <= i then begin
    let a =
      Multicore_magic.make_padded_array (Int.max (n * 2) (i + 1)) (null ())
    in
    for i = 0 to n - 1 do
      Array.unsafe_set a i (Array.unsafe_get !ar i)
    done;
    ar := a
  end;
  Array.unsafe_set !ar i x

let prepare () =
  Mutex.lock mutex;
  Idle_domains.all ()
  |> List.iter (fun (id : Idle_domains.managed_id) ->
         set workers (id :> int) (DCYL.make ()));
  Mutex.unlock mutex

let prepare (id : Idle_domains.managed_id) =
  if
    Multicore_magic.length_of_padded_array !workers <= (id :> int)
    || null () == worker_at (id :> int)
  then prepare ()
  [@@inline]

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
  dispatch res @@ Atomic.exchange st res

let run_work (Work st) =
  match Multicore_magic.fenceless_get st with
  | Initial th as was ->
    if Atomic.compare_and_set st was Running then run_fiber st th |> ignore
  | _ -> ()

let rec loop dcyl =
  let work = DCYL.pop dcyl in
  Effect.Deep.match_with run_work work handler;
  loop dcyl

let rounds = 2

let rec main wr =
  try loop wr
  with DCYL.Empty ->
    DCYL.reset wr;
    try_steal wr rounds @@ Idle_domains.next @@ Idle_domains.self ()

and try_steal wr rounds id =
  let victim = worker_at (id :> int) in
  if victim != wr then
    match DCYL.steal victim with
    | work ->
      if DCYL.seems_non_empty victim then Idle_domains.signal ();
      Effect.Deep.match_with run_work work handler;
      main wr
    | exception DCYL.Empty -> try_steal wr rounds @@ Idle_domains.next id
  else
    let rounds = rounds - 1 in
    if 0 < rounds then begin
      try_steal wr rounds @@ Idle_domains.next id
    end

let scheduler (mid : Idle_domains.managed_id) =
  let wr = worker_at (mid :> int) in
  try_steal wr rounds @@ Idle_domains.next mid

let push wr work =
  Idle_domains.signal ();
  DCYL.push wr work
  [@@inline]

(* *)

let num_runs = Multicore_magic.copy_as_padded (Atomic.make 0)

let run ef =
  let self = Idle_domains.self () in
  prepare self;
  if Atomic.fetch_and_add num_runs 1 = 0 then Idle_domains.register ~scheduler;
  let result = ref (null ()) in
  Effect.Deep.match_with
    (fun ef ->
      (result := match ef () with v -> Ok v | exception e -> Error e);
      Idle_domains.wakeup ~self;
      if Atomic.fetch_and_add num_runs (-1) = 1 then
        Idle_domains.unregister ~scheduler)
    ef handler;
  main @@ worker_at (self :> int);
  Idle_domains.idle ~self;
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
