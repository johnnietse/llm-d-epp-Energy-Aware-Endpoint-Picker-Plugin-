package probe

import "errors"

var errNoParams = errors.New(Type + " takes no parameters; it is an inert plumbing probe, not a tunable policy")
