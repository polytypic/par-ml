[@@@alert "-unstable"]

let null _ = Obj.magic () [@@inline]
let impossible () = failwith "impossible"

(* *)

let mutex = Mutex.create ()

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

and stack = Work : 'a st Atomic.t * stack -> stack | Null : stack

(* *)

let shared = Multicore_magic.copy_as_padded (Atomic.make Null)

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
         set workers (id :> int) (Multicore_magic.copy_as_padded (ref Null)));
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
      | Return x -> Continuation.return k x
      | Raise e -> Continuation.raise k e
      | _ -> impossible ()
    end;
    dispatch res ws
  | _ -> res

let run_fiber st th =
  let res = match th () with x -> Return x | exception e -> Raise e in
  dispatch res (Atomic.exchange st res)

let doit st =
  match Multicore_magic.fenceless_get st with
  | Initial th as was ->
    if Atomic.compare_and_set st was Running then run_fiber st th |> ignore
  | _ -> ()

let rec main wr =
  match !wr with
  | Work (st, next) ->
    if
      next != Null
      && Multicore_magic.fenceless_get shared == Null
      && Atomic.compare_and_set shared Null next
    then begin
      Idle_domains.try_spawn ~scheduler |> ignore;
      wr := Null
    end
    else wr := next;
    Effect.Deep.try_with doit st handler;
    main wr
  | Null -> try_shared wr

and try_shared wr =
  match Multicore_magic.fenceless_get shared with
  | Null -> ()
  | Work (st, next) as top ->
    if not (Atomic.compare_and_set shared top next) then try_shared wr
    else begin
      if next != Null then Idle_domains.try_spawn ~scheduler |> ignore;
      Effect.Deep.try_with doit st handler;
      main wr
    end

and scheduler (mid : Idle_domains.managed_id) =
  try_shared @@ worker_at (mid :> int)

let push wr work =
  let next = !wr in
  if
    next != Null
    && Multicore_magic.fenceless_get shared == Null
    && Atomic.compare_and_set shared Null next
  then begin
    Idle_domains.try_spawn ~scheduler |> ignore;
    wr := Work (work, Null)
  end
  else wr := Work (work, next)
  [@@inline]

let drop_if wr st' =
  match !wr with
  | Work (st, next) when st == Obj.magic st' -> wr := next
  | _ -> ()

(* *)

let not_null result = !result != null ()

let run ef =
  let mid = Idle_domains.self () in
  prepare mid;
  let result = ref (null ()) in
  Effect.Deep.try_with
    (fun ef ->
      (result := match ef () with v -> Ok v | exception e -> Error e);
      Idle_domains.wakeup mid)
    ef handler;
  main @@ worker_at (mid :> int);
  Idle_domains.idle ~until:not_null result;
  Result.run !result

(* *)

let par tha thb =
  let st = Atomic.make @@ Initial tha in
  let wr = worker () in
  push wr st;
  match thb () with
  | y -> begin
    match Atomic.exchange st Running with
    | Return x -> (x, y)
    | Raise e -> raise e
    | Initial tha ->
      drop_if wr st;
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
      | Initial _ -> drop_if wr st |> null
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
  type 'a t = 'a st Atomic.t

  let spawn th =
    let st = Atomic.make @@ Initial th in
    let wr = worker () in
    push wr st;
    st

  let rec join st =
    match Multicore_magic.fenceless_get st with
    | Initial th as t ->
      if Atomic.compare_and_set st t Running then begin
        let wr = worker () in
        drop_if wr st;
        match run_fiber st th with
        | Return x -> x
        | Raise e -> raise e
        | _ -> impossible ()
      end
      else join st
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
