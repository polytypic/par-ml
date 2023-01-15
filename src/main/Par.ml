[@@@alert "-unstable"]

let null _ = Obj.magic () [@@inline]
let impossible () = failwith "impossible"

(* *)

let mutex = Mutex.create ()

(* *)

let atomic_get_compare_and_set atomic expected desired =
  if Multicore_magic.fenceless_get atomic == expected then
    Atomic.compare_and_set atomic expected desired |> ignore
  [@@inline]

(* *)

type 'a continuation = ('a, unit) Effect.Deep.continuation
type _ Effect.t += Suspend : ('a continuation -> unit) -> 'a Effect.t

let effc (type a) : a Effect.t -> _ = function
  | Suspend ef -> Some ef
  | _ -> None

let handler =
  Multicore_magic.copy_as_padded {Effect.Deep.retc = ignore; exnc = raise; effc}

let handle ef x = Effect.Deep.match_with ef x handler [@@inline]

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
         set workers
           (id :> int)
           (Multicore_magic.copy_as_padded (Atomic.make Null)));
  Mutex.unlock mutex

let prepare (id : Idle_domains.managed_id) =
  if
    Multicore_magic.length_of_padded_array !workers <= (id :> int)
    || null () == Array.unsafe_get !workers (id :> int)
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

let run_under_current_handler st th =
  let res = match th () with x -> Return x | exception e -> Raise e in
  dispatch res (Atomic.exchange st res)
  [@@inline]

let run_with_global_handler st th =
  handle (fun th -> run_under_current_handler st th |> ignore) th
  [@@inline]

let rec main wr =
  match Multicore_magic.fenceless_get wr with
  | Work (st, next) as top ->
    if Atomic.compare_and_set wr top next then begin
      match Multicore_magic.fenceless_get st with
      | Initial th as was when Atomic.compare_and_set st was Running ->
        if Null != next then Idle_domains.try_spawn ~scheduler |> ignore;
        run_with_global_handler st th
      | _ -> ()
    end;
    main wr
  | Null -> try_steal wr (Idle_domains.next (Idle_domains.self ()))

and try_steal wr (mid : Idle_domains.managed_id) =
  let victim = worker_at (mid :> int) in
  if victim != wr then try_steal_from wr mid victim

and try_steal_from wr mid victim =
  match Multicore_magic.fenceless_get victim with
  | Work (st1, Work (st2, next)) as top -> begin
    match Multicore_magic.fenceless_get st2 with
    | Initial th as was when Atomic.compare_and_set st2 was Running ->
      if Multicore_magic.fenceless_get victim == top then begin
        Atomic.compare_and_set victim top (Work (st1, next)) |> ignore;
        Idle_domains.try_spawn ~scheduler |> ignore
      end;
      run_with_global_handler st2 th;
      main wr
    | _ -> begin
      match Multicore_magic.fenceless_get st1 with
      | Initial th as was when Atomic.compare_and_set st1 was Running ->
        atomic_get_compare_and_set victim top next;
        run_with_global_handler st1 th;
        main wr
      | _ ->
        atomic_get_compare_and_set victim top next;
        try_steal_from wr mid victim
    end
  end
  | Work (st, next) as top -> begin
    match Multicore_magic.fenceless_get st with
    | Initial th as was when Atomic.compare_and_set st was Running ->
      atomic_get_compare_and_set victim top next;
      run_with_global_handler st th;
      main wr
    | _ ->
      atomic_get_compare_and_set victim top next;
      try_steal_from wr mid victim
  end
  | Null -> try_steal wr (Idle_domains.next mid)

and scheduler mid =
  let wr = worker_at (mid :> int) in
  try_steal wr (Idle_domains.next mid)

(* *)

let rec push wr st =
  let top = Multicore_magic.fenceless_get wr in
  if Atomic.compare_and_set wr top (Work (st, top)) then
    Idle_domains.try_spawn ~scheduler |> ignore
  else push wr st
  [@@inline]

let drop_if wr st' =
  match Multicore_magic.fenceless_get wr with
  | Work (st, next) as top when st == Obj.magic st' ->
    Atomic.compare_and_set wr top next |> ignore
  | _ -> ()
  [@@inline]

(* *)

let not_null result = !result != null ()

let run ef =
  let mid = Idle_domains.self () in
  prepare mid;
  if 0 <> (Domain.self () :> int) then failwith "only main domain may call run";
  let result = ref (null ()) in
  handle
    (fun ef ->
      (result := match ef () with v -> Ok v | exception e -> Error e);
      Idle_domains.wakeup mid)
    ef;
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
        match run_under_current_handler st th with
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
