[@@@alert "-unstable"]
[@@@ocaml.warning "-69"] (* Disable unused field warning. *)

let null _ = Obj.magic () [@@inline]
let impossible () = failwith "impossible"

(* *)

type 'a continuation = ('a, unit) Effect.Deep.continuation
type _ Effect.t += Suspend : ('a continuation -> unit) -> 'a Effect.t

let effc (type a) : a Effect.t -> _ = function
  | Suspend ef -> Some ef
  | _ -> None

let handler = {Effect.Deep.effc}
let handle work = Effect.Deep.try_with work () handler [@@inline]

(* *)

type state = {
  p1 : int;
  p2 : int;
  p3 : int;
  p4 : int;
  p5 : int;
  p6 : int;
  p7 : int;
  p8 : int;
  p9 : int;
  pA : int;
  pB : int;
  pC : int;
  pD : int;
  pE : int;
  mutable num_waiters_non_zero : bool;
  m1 : int;
  m2 : int;
  m3 : int;
  m4 : int;
  m5 : int;
  m6 : int;
  m7 : int;
  m8 : int;
  m9 : int;
  mA : int;
  mB : int;
  mC : int;
  mD : int;
  mE : int;
  mF : int;
  mutable num_waiters : int;
  s1 : int;
  s2 : int;
  s3 : int;
  s4 : int;
  s5 : int;
  s6 : int;
  s7 : int;
  s8 : int;
  s9 : int;
  sA : int;
  sB : int;
  sC : int;
  sD : int;
  sE : int;
  sF : int;
}

let state =
  {
    p1 = 0;
    p2 = 0;
    p3 = 0;
    p4 = 0;
    p5 = 0;
    p6 = 0;
    p7 = 0;
    p8 = 0;
    p9 = 0;
    pA = 0;
    pB = 0;
    pC = 0;
    pD = 0;
    pE = 0;
    num_waiters_non_zero = false;
    m1 = 0;
    m2 = 0;
    m3 = 0;
    m4 = 0;
    m5 = 0;
    m6 = 0;
    m7 = 0;
    m8 = 0;
    m9 = 0;
    mA = 0;
    mB = 0;
    mC = 0;
    mD = 0;
    mE = 0;
    mF = 0;
    num_waiters = 0;
    s1 = 0;
    s2 = 0;
    s3 = 0;
    s4 = 0;
    s5 = 0;
    s6 = 0;
    s7 = 0;
    s8 = 0;
    s9 = 0;
    sA = 0;
    sB = 0;
    sC = 0;
    sD = 0;
    sE = 0;
    sF = 0;
  }

let mutex = Mutex.create ()
let condition = Condition.create ()

type worker = (unit -> unit) DCYL.t

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
  Array.init num_workers (fun _ -> null ())

let rec loop dcyl =
  let work = DCYL.pop dcyl in
  handle work;
  loop dcyl

let next_index i =
  let i = i + 1 in
  if i < Array.length workers then i else 0
  [@@inline]

let first_index () = next_index (Domain.self () :> int) [@@inline]

let add_waiter () =
  let n = state.num_waiters + 1 in
  state.num_waiters <- n;
  if n = 1 then state.num_waiters_non_zero <- true;
  Condition.wait condition mutex;
  let n = state.num_waiters - 1 in
  state.num_waiters <- n;
  if n = 0 then state.num_waiters_non_zero <- false

let rec main wr = try loop wr with DCYL.Empty -> try_steal wr (first_index ())

and try_steal wr i =
  let victim = Array.unsafe_get workers i in
  if victim == wr then wait wr i
  else
    match DCYL.steal victim with
    | work ->
      handle work;
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
    if Array.length workers <= i then failwith "add_worker: not sequential";
    let wr = DCYL.make () in
    Mutex.lock mutex;
    Array.unsafe_set workers i wr;
    incr num_workers';
    if !num_workers' = Array.length workers then Condition.broadcast condition;
    Mutex.unlock mutex;
    wr
  in

  let wait_ready () =
    Mutex.lock mutex;
    while !num_workers' <> Array.length workers do
      Condition.wait condition mutex
    done;
    Mutex.unlock mutex
  in

  add_worker () |> ignore;
  for _ = 2 to Array.length workers do
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
  if state.num_waiters_non_zero then Condition.signal condition
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
  if 0 <> (Domain.self () :> int) then failwith "only main domain may call run";
  let res = ref (null ()) in
  handle (fun () ->
      match ef () with v -> res := Ok v | exception e -> res := Error e);
  while !res == null () do
    main (Array.unsafe_get workers 0)
  done;
  !res |> Result.run

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
