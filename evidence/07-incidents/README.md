# C7 incident replay evidence (individual)

One folder per incident. Pick **one** for the full walk-through (fault →
alert fires → dashboard → mechanism in prose). The other three are alert-only.

`up{job="capacity-api"} == 0` is the cheapest 2204 injection (`docker kill`
the app container).
