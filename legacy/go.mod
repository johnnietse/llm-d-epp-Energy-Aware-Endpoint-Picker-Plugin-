// Separate module so that `go build ./...` and `go test ./...` at the
// repository root ignore everything under legacy/.
//
// This code is PRESERVED SOURCE, not a buildable target. It was moved here by
// the 2026-10-03 rescope and its imports still point at the root module's
// packages, so it does not compile in place. The last commit where this code
// built and passed tests alongside the rest is tagged:
//
//     pre-rescope-2026-10-03   (bda1f97)
//
// Check that tag out if you need it to run. See ./README.md for why each piece
// is here and docs/plan/FINAL-PLAN-2026-10.md section 2 for the decisions.
module github.com/johnnie/energy-aware-epp-legacy

go 1.25.0
