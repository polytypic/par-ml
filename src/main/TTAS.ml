[@@@alert "-unstable"]

type t = bool Atomic.t

let make () = Atomic.make false

let rec acquire lock =
  while Atomic.get lock do
    Domain.cpu_relax ()
  done;
  if not (Atomic.compare_and_set lock false true) then acquire lock

let release l = Atomic.set l false

let protect lock th =
  acquire lock;
  Fun.protect ~finally:(fun () -> release lock) th
