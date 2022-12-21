type t
type holder

val make : unit -> t
val acquire : t -> holder
val release : t -> holder -> unit
val protect : t -> (unit -> unit) -> unit
