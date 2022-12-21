[@@@alert "-unstable"]

type state = Spinning | Released
type holder = state Atomic.t Atomic.t
type t = holder Atomic.t

let null () = Obj.magic () [@@inline]
let make () = Atomic.make (null ())

let acquire lock =
  let holder = Atomic.make (null ()) in
  let pred = Atomic.exchange lock holder in
  if pred != null () then begin
    let state = Atomic.make Spinning in
    Atomic.set pred state;
    while Spinning <> Atomic.get state do
      Domain.cpu_relax ()
    done
  end;
  holder

let rec release lock holder =
  let state = Atomic.get holder in
  if state != null () then Atomic.set state Released
  else if not (Atomic.compare_and_set lock holder (null ())) then begin
    Domain.cpu_relax ();
    release lock holder
  end

let protect lock th =
  let holder = acquire lock in
  Fun.protect ~finally:(fun () -> release lock holder) th
