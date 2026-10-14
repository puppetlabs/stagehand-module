# @summary A certificate's SHA-256 fingerprint in colon hex.
#
# 32 hex pairs joined by colons, the `(SHA256)` value `puppetserver ca list
# --all` prints and the form `openssl x509 -noout -fingerprint -sha256` gives
# after its `sha256 Fingerprint=` label, for example
# `5B:9A:0C:...:3D:B5`. Copy only the hex: the `(SHA256)` label, a SHA-1
# fingerprint (20 pairs), bare hex without colons and any surrounding
# whitespace are refused. Lower case is accepted, as the webhook-go fork
# accepts it; `stagehand::webhook` renders every entry in upper case.
type Stagehand::Sha256_fingerprint = Pattern[/\A[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){31}\z/]
