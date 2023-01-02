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
         let prefix = "--num_workers=" in
         if String.starts_with ~prefix arg then
           let n = String.length prefix in
           String.sub arg n (String.length arg - n) |> int_of_string_opt
         else None)
  |> Option.value ~default:(Domain.recommended_domain_count ())

let workers = Array.init num_workers (fun _ -> DCYL.make ())

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
    Mutex.protect mutex (fun () ->
        incr num_waiters;
        Condition.wait condition mutex;
        decr num_waiters);
    try_steal wr
  end

let () =
  let num_workers' = ref 0 in

  let add_worker () =
    let i = (Domain.self () :> int) in
    if Array.length workers <= i then failwith "add_worker: not sequential";
    Mutex.protect mutex @@ fun () ->
    incr num_workers';
    Condition.broadcast condition;
    workers.(i)
  in

  add_worker () |> ignore;
  for _ = 2 to num_workers do
    Domain.spawn (fun () ->
        let wr = add_worker () in
        main wr)
    |> ignore
  done;
  Mutex.protect mutex @@ fun () ->
  while !num_workers' <> num_workers do
    Condition.wait condition mutex
  done

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

type ('a, 'b) par =
  | Initial
  | LeftOk of 'a
  | LeftError of exn
  | RightOk of ('a * 'b) Continuation.t * 'b
  | RightError of ('a * 'b) Continuation.t * exn

let par tha thb =
  let st = Atomic.make Initial in
  let work () =
    match tha () with
    | x -> begin
      match Atomic.get st with
      | RightOk (k, y) -> Continuation.return k (x, y)
      | RightError (k, e) -> Continuation.raise k e
      | initial ->
        if not (Atomic.compare_and_set st initial (LeftOk x)) then begin
          match Atomic.get st with
          | RightOk (k, y) -> Continuation.return k (x, y)
          | RightError (k, e) -> Continuation.raise k e
          | _ -> impossible ()
        end
    end
    | exception e -> begin
      match Atomic.get st with
      | RightOk (k, _) | RightError (k, _) -> Continuation.raise k e
      | initial ->
        if not (Atomic.compare_and_set st initial (LeftError e)) then begin
          match Atomic.get st with
          | RightOk (k, _) | RightError (k, _) -> Continuation.raise k e
          | _ -> impossible ()
        end
    end
  in
  let wr = worker () in
  let i = DCYL.mark wr in
  push wr work;
  match thb () with
  | y -> begin
    match Atomic.get st with
    | LeftOk x -> (x, y)
    | LeftError e -> raise e
    | initial ->
      if DCYL.drop_at wr i then (tha (), y)
      else
        Continuation.suspend @@ fun k ->
        if not (Atomic.compare_and_set st initial (RightOk (k, y))) then begin
          match Atomic.get st with
          | LeftOk x -> Continuation.return k (x, y)
          | LeftError e -> Continuation.raise k e
          | _ -> impossible ()
        end
  end
  | exception e -> begin
    match Atomic.get st with
    | LeftOk _ -> raise e
    | LeftError e -> raise e
    | initial ->
      if DCYL.drop_at wr i then raise e
      else
        Continuation.suspend @@ fun k ->
        if not (Atomic.compare_and_set st initial (RightError (k, e))) then
          let e = match Atomic.get st with LeftError e -> e | _ -> e in
          Continuation.raise k e
  end

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
