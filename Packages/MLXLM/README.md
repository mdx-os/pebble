# MLXLM

A copy of two libraries from [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm),
`MLXLLM` and `MLXLMCommon`, which the on-device model adapter in
`PebbleKit/Sources/PebbleModel` uses.

- Upstream: https://github.com/ml-explore/mlx-swift-lm
- Version: 3.32.3
- Commit: 3b339ad6e3b3f44c8121ecff5131c7fd55e075e6
- License: MIT, kept as upstream wrote it in [LICENSE](LICENSE)

`Sources/MLXLLM` and `Sources/MLXLMCommon` are upstream's
`Libraries/MLXLLM` and `Libraries/MLXLMCommon` at that commit, file for
file and unchanged, without their `README.md` and `Documentation.docc`.
About 2.9 MB: 198 Swift files, 67,635 lines.

Why a copy: upstream's package also builds a macro, and that macro depends
on swift-syntax. Depending on the published package puts swift-syntax in
PebbleKit's resolved file, and `make graph-check` keeps swift-syntax out of
the app's graph. These two libraries never use the macro, so `Package.swift`
here leaves it out and depends only on mlx-swift.

To move to a new upstream version, replace both folders with that version's
`Libraries/MLXLLM` and `Libraries/MLXLMCommon`, update the version and
commit above and in `Package.swift`, and check `LICENSE` against upstream's.
`OnDeviceLoad` in PebbleModel takes the same steps as `LLMModelFactory._load`
here, so read its notes and run `make model-test` too.
