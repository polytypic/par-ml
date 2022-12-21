include Stdlib.Mutex

let protect mutex block =
  lock mutex;
  Fun.protect ~finally:(fun () -> unlock mutex) block
