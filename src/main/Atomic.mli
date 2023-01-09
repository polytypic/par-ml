include module type of Stdlib.Atomic

val make_fat : 'a -> 'a t
val fence : int t -> unit
