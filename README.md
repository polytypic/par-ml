# Experimental parallel and concurrent OCaml

Compared to [lockfree](https://github.com/ocaml-multicore/lockfree)
work-stealing deque:

- Only
  [a single atomic variable](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/DCYL.ml#L12)
  is used (closer to
  [original paper](https://www.semanticscholar.org/paper/Dynamic-circular-work-stealing-deque-Chase-Lev/f856a996e7aec0ea6db55e9247a00a01cb695090)).
- A level of (pointer) indirection is avoided by using
  [a different technique to release stolen elements](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/DCYL.ml#L37-L46).
- [`mark` and `drop_at` operations](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/DCYL.mli#L20-L25)
  are provided to allow owner to remove elements from deque without dropping to
  main loop (see
  [here](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.ml#L156)
  and
  [here](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.ml#L164),
  for example).

Compared to [domainslib](https://github.com/ocaml-multicore/domainslib):

- A more general
  [`Suspend` effect](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.ml#L9)
  is used to allow synchronization primitives to be built on top of the
  scheduler.
- The pool of workers is not exposed. The idea is that there is only one system
  level pool of workers to be used by all parallel and concurrent code.
  [`Domain.self ()` is used as index](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.ml#L90)
  and are assumed to be consecutive numbers in the range `[0, n[`.
- A lower overhead
  [`par` operation](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.mli#L4-L6)
  is provided for parallel execution. It avoids need to maintain a list of
  readers.

TODO:

- Is the
  [work-stealing deque](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/DCYL.ml)
  implementation correct?
- Implement more scalable wake-up mechanism.
- Support for cancellation.
- `sleep` mechanism.
- Composable synchronization primitives (e.g. ability to `race` fibers).
- Various synchronization primitives (mutex, condition, ...) as examples.

## Benchmarks to be taken with plenty of salt

These have been run on Apple M1 with 4 + 4 cores in low power mode.

```sh
➜  par-ml git:(main) for d in 1 2 4 8; do time FibFiber.exe --num_workers=$d 40; done
fib 40 = 102334155
FibFiber.exe --num_workers=$d 40  8.16s user 0.02s system 99% cpu 8.185 total
fib 40 = 102334155
FibFiber.exe --num_workers=$d 40  8.82s user 0.02s system 199% cpu 4.437 total
fib 40 = 102334155
FibFiber.exe --num_workers=$d 40  16.47s user 0.05s system 396% cpu 4.165 total
fib 40 = 102334155
FibFiber.exe --num_workers=$d 40  36.49s user 0.60s system 691% cpu 5.366 total
```

```sh
➜  par-ml git:(main) ✗ for d in 1 2 4 8; do time FibPar.exe --num_workers=$d 40; done
fib 40 = 102334155
FibPar.exe --num_workers=$d 40  5.70s user 0.01s system 99% cpu 5.718 total
fib 40 = 102334155
FibPar.exe --num_workers=$d 40  6.66s user 0.02s system 198% cpu 3.353 total
fib 40 = 102334155
FibPar.exe --num_workers=$d 40  13.54s user 0.04s system 395% cpu 3.436 total
fib 40 = 102334155
FibPar.exe --num_workers=$d 40  27.18s user 0.49s system 684% cpu 4.042 total
```

In the following, the `fib_par` example of domainslib

```ocaml
let rec fib_par pool n =
  if n < 2 then n
  else
    let b = T.async pool (fun _ -> fib_par pool (n - 1)) in
    let a = fib_par pool (n - 2) in
    a + T.await pool b
```

has been modified as above

- to not drop down to sequential version (intention is to measure overheads),
- to perform better (using fewer `async`/`await`s), and
- to give same numerical result as the `par-ml` versions.

```sh
➜  domainslib git:(master) ✗ for d in 1 2 4 8; do time fib_par.exe $d 40; done
fib(40) = 102334155
fib_par.exe $d 40  47.10s user 0.12s system 99% cpu 47.223 total
fib(40) = 102334155
fib_par.exe $d 40  60.76s user 0.10s system 199% cpu 30.450 total
fib(40) = 102334155
fib_par.exe $d 40  83.00s user 0.13s system 397% cpu 20.890 total
fib(40) = 102334155
fib_par.exe $d 40  193.91s user 1.12s system 707% cpu 27.579 total
```

```sh
➜  domainslib git:(master) ✗ for d in 1 2 4 8; do time fib_par.exe $d 40; done
fib(40) = 102334155
fib_par.exe $d 40  48.28s user 0.08s system 99% cpu 48.365 total
fib(40) = 102334155
fib_par.exe $d 40  61.77s user 0.07s system 199% cpu 30.943 total
fib(40) = 102334155
fib_par.exe $d 40  82.72s user 0.13s system 397% cpu 20.824 total
fib(40) = 102334155
fib_par.exe $d 40  193.92s user 1.12s system 717% cpu 27.172 total
```
