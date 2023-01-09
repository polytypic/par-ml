[@@@alert "-unstable"]

let null _ = Obj.magic () [@@inline]
let impossible () = failwith "impossible"

(* *)

let mutex = Mutex.create ()
let condition = Condition.create ()

(* *)

let result_ready = Multicore.copy_as_padded (ref true)

(* *)

type 'a continuation = ('a, unit) Effect.Deep.continuation
type _ Effect.t += Suspend : ('a continuation -> unit) -> 'a Effect.t

let effc (type a) : a Effect.t -> _ = function
  | Suspend ef -> Some ef
  | _ -> None

let handler =
  Multicore.copy_as_padded {Effect.Deep.retc = ignore; exnc = raise; effc}

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

let num_waiters_non_zero = Multicore.copy_as_padded (ref false)
let num_waiters = Multicore.copy_as_padded (ref 0)

let workers =
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
  in
  Multicore.copy_as_padded
    (Array.init num_workers (fun _ ->
         Multicore.copy_as_padded (Atomic.make Null)))

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

let next_index i =
  let i = i + 1 in
  if i < Multicore.length_of_padded_array workers then i else 0
  [@@inline]

let first_index () = next_index (Domain.self () :> int) [@@inline]

let rec main wr =
  match Atomic.get wr with
  | Work (st, next) as top ->
    if Atomic.compare_and_set wr top next then begin
      match Atomic.get st with
      | Initial th as was when Atomic.compare_and_set st was Running ->
        if Null != next && !num_waiters_non_zero then Condition.signal condition;
        run_with_global_handler st th
      | _ -> ()
    end;
    main wr
  | Null -> try_steal wr (first_index ())

and try_steal wr i =
  let victim = Array.unsafe_get workers i in
  if victim == wr then wait wr i else try_steal_from wr i victim

and try_steal_from wr i victim =
  match Atomic.get victim with
  | Work (st1, Work (st2, next)) as top -> begin
    match Atomic.get st2 with
    | Initial th as was when Atomic.compare_and_set st2 was Running ->
      Atomic.get_compare_and_set victim top (Work (st1, next));
      run_with_global_handler st2 th;
      main wr
    | _ -> begin
      match Atomic.get st1 with
      | Initial th as was when Atomic.compare_and_set st1 was Running ->
        Atomic.get_compare_and_set victim top next;
        run_with_global_handler st1 th;
        main wr
      | _ ->
        Atomic.get_compare_and_set victim top next;
        try_steal_from wr i victim
    end
  end
  | Work (st, next) as top -> begin
    match Atomic.get st with
    | Initial th as was when Atomic.compare_and_set st was Running ->
      Atomic.get_compare_and_set victim top next;
      run_with_global_handler st th;
      main wr
    | _ ->
      Atomic.get_compare_and_set victim top next;
      try_steal_from wr i victim
  end
  | Null -> try_steal wr (next_index i)

and wait wr i =
  if i <> 0 || not !result_ready then begin
    Mutex.lock mutex;
    let n = !num_waiters + 1 in
    num_waiters := n;
    if n = 1 then num_waiters_non_zero := true;
    if i <> 0 || not !result_ready then Condition.wait condition mutex;
    let n = !num_waiters - 1 in
    num_waiters := n;
    if n = 0 then num_waiters_non_zero := false;
    Mutex.unlock mutex;
    try_steal wr (next_index i)
  end

let () =
  for _ = 2 to Multicore.length_of_padded_array workers do
    Domain.spawn (fun () ->
        let i = (Domain.self () :> int) in
        if Multicore.length_of_padded_array workers <= i then
          failwith "add_worker: not sequential";
        let wr = Array.unsafe_get workers i in
        main wr)
    |> ignore
  done

(* *)

let worker () = workers.((Domain.self () :> int)) [@@inline]

let rec push wr st =
  let top = Atomic.get wr in
  if Atomic.compare_and_set wr top (Work (st, top)) then begin
    if !num_waiters_non_zero then Condition.signal condition
  end
  else push wr st
  [@@inline]

let drop_if wr st' =
  match Atomic.get wr with
  | Work (st, next) as top when st == Obj.magic st' ->
    Atomic.compare_and_set wr top next |> ignore
  | _ -> ()
  [@@inline]

(* *)

let run ef =
  if 0 <> (Domain.self () :> int) then failwith "only main domain may call run";
  if not !result_ready then failwith "run is not re-entrant";
  result_ready := false;
  let wr = Array.unsafe_get workers 0 in
  let result = ref (null ()) in
  handle
    (fun ef ->
      (result := match ef () with v -> Ok v | exception e -> Error e);
      Mutex.lock mutex;
      result_ready := true;
      Condition.broadcast condition;
      Mutex.unlock mutex)
    ef;
  main wr;
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
    match Atomic.get st with
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
          match Atomic.get st with
          | Return x -> Continuation.return k x
          | Raise e -> Continuation.raise k e
          | was -> loop was
      in
      loop was
end
