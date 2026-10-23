# OpenList embedded cloud core

- Upstream: https://github.com/OpenListTeam/OpenList
- Version: v4.2.6, commit `2bdf16d5967d0a403f67d809efd5a418b8f5bd30`.
- License: GNU Affero General Public License v3.0; see `LICENSE`.
- The upstream authors retain copyright in their respective contributions.
- Local adapter: `cloud/openlist/cloudcore.go` in this repository. The build changes the GORM tag on `Storage.Addition` to `serializer:vrpp_secret` to encrypt provider credentials, and adds the search extensions in `cloud/openlist/search/` to the corresponding driver packages. Search reuses each driver's existing authentication and token refresh logic; no upstream files other than the credential tag are rewritten.
- Build recipe and exact archive hashes: `tools/environment/Prepare-OpenList.ps1`.
- Go: 1.27.1. Android binding: `golang.org/x/mobile` at `v0.0.0-20260908204917-8b95e45f8d3e` (BSD-3-Clause).
- The APK uses an in-process core, a private JNI management interface, and a capability-protected loopback media router. It does not embed OpenList's frontend or the OpenList-Mobile app.

For distribution, provide the player's corresponding source together with this adapter, the build script, upstream source at the pinned revision, module manifests, and dependency licenses. This notice is not a replacement for corresponding-source delivery.

Archive page reading also uses the pinned upstream modules github.com/KirCute/zip v1.0.1, github.com/bodgit/sevenzip v1.6.5 and github.com/nwaples/rardecode/v2 v2.4.1. Their original notices are retained under dependencies/; keep their transitive notices and exact module sources with binary redistribution.
