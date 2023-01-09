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
  | Return of 'a
  | Raise of exn

and stack = Work : 'a st Atomic.t * stack -> stack | Null : stack

(* *)

let shared = Multicore.copy_as_padded (ref Null)

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
    (Array.init num_workers (fun _ -> Multicore.copy_as_padded (ref Null)))

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
  match Atomic.get st with
  | Initial th as was ->
    if Atomic.compare_and_set st was Running then run_fiber st th |> ignore
  | _ -> ()

let rec main wr result = function
  | Work (st, next) ->
    if next != Null && !shared == Null then begin
      Mutex.lock mutex;
      if !shared == Null then begin
        shared := next;
        Condition.signal condition;
        Mutex.unlock mutex;
        wr := Null
      end
      else begin
        Mutex.unlock mutex;
        wr := next
      end
    end
    else wr := next;
    Effect.Deep.try_with doit st handler;
    main wr result !wr
  | Null ->
    wr := Null;
    Mutex.lock mutex;
    while !shared == Null && !result == null () do
      Condition.wait condition mutex
    done;
    let top = !shared in
    shared := Null;
    Mutex.unlock mutex;
    if !result == null () then main wr result top

let () =
  let always_null = Multicore.copy_as_padded (ref (null ())) in

  for _ = 2 to Multicore.length_of_padded_array workers do
    Domain.spawn (fun () ->
        let i = (Domain.self () :> int) in
        if Multicore.length_of_padded_array workers <= i then
          failwith "add_worker: not sequential";
        let wr = Array.unsafe_get workers i in
        main wr always_null !wr)
    |> ignore
  done

let worker () = workers.((Domain.self () :> int)) [@@inline]

let push wr work =
  let next = !wr in
  if next != Null && !shared == Null then begin
    Mutex.lock mutex;
    if !shared == Null then begin
      shared := next;
      Condition.signal condition;
      Mutex.unlock mutex;
      wr := Work (work, Null)
    end
    else begin
      Mutex.unlock mutex;
      wr := Work (work, next)
    end
  end
  else wr := Work (work, next)
  [@@inline]

let drop_if wr st' =
  match !wr with
  | Work (st, next) when st == Obj.magic st' -> wr := next
  | _ -> ()

(* *)

let run ef =
  if 0 <> (Domain.self () :> int) then failwith "only main domain may call run";
  let result = ref (null ()) in
  Effect.Deep.try_with
    (fun ef ->
      let r = match ef () with v -> Ok v | exception e -> Error e in
      Mutex.lock mutex;
      result := r;
      Condition.broadcast condition;
      Mutex.unlock mutex)
    ef handler;
  let wr = Array.unsafe_get workers 0 in
  main wr result !wr;
  let res = !result in
  result := null ();
  Result.run res

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
          match Atomic.get st with
          | Return x -> Continuation.return k x
          | Raise e -> Continuation.raise k e
          | was -> loop was
      in
      loop was
end
