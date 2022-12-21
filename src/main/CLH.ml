[@@@alert "-unstable"]

type holder = bool Atomic.t
type t = holder Atomic.t

let released = Atomic.make true
let make () = Atomic.make released

let acquire lock =
  let holder = Atomic.make false in
  let other = Atomic.exchange lock holder in
  while not (Atomic.get other) do
    Domain.cpu_relax ()
  done;
  holder

let release lock holder =
  Atomic.set holder true;
  if Atomic.get lock == holder then
    Atomic.compare_and_set lock holder released |> ignore

let protect lock th =
  let holder = acquire lock in
  Fun.protect ~finally:(fun () -> release lock holder) th
