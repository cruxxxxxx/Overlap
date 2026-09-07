# overlap-clip — semantic search for Overlap

A `capabilities: ["search"]` plugin. Embeds every image with a MobileCLIP image
encoder into one persisted index and answers free-text queries ("girl with
spiral hair") by encoding the text with the matching text encoder and ranking
the index by cosine similarity. Everything runs on-device.

## Models

Apple's Core ML exports from <https://huggingface.co/apple/coreml-mobileclip>
(default variant **S2**: image encoder 72 MB + text encoder 127 MB, fp16).
They are **downloaded on first use** — the app bundle stays small — into

```
~/Library/Application Support/Overlap/PluginCache/overlap-clip/
  models/mobileclip_s2_image.mlmodelc
  models/mobileclip_s2_text.mlmodelc
  models/VERSION          # variant the compiled models belong to
  clip.bin                # float32 rows, L2-normalized, one per indexed image
  meta.json               # path → {sig, row}; rows survive a killed run
  config.json             # variant, batchSize, decodeMaxPixel, … (self-documenting)
```

Model weights are under Apple's ML Research Model terms of use; the tokenizer
sources (`CLIPTokenizer.swift`, `GPT2ByteEncoder.swift`, `TokenizerUtils.swift`)
are Hugging Face's, MIT, from Apple's `ml-mobileclip` iOS demo, with the vocab
(`clip-vocab.json`) and merges (`clip-merges.txt`) alongside.

To try another variant, edit `config.json` → `"variant": "s0" | "s1" | "s2" | "blt"`
and run Plugins ▸ Rebuild Search Index. Vectors from different encoders aren't
comparable, so the index is rebuilt from scratch.

## Settings (Plugins ▸ Plugin Settings…)

| key | default | meaning |
|---|---|---|
| `maxResults` | 300 | hits returned per query |
| `minScore` | 0.15 | CLIP cosine cutoff; good matches usually land 0.2–0.35 |
| `maxFileMB` | 25 | larger files are skipped when indexing |

## Try it from the shell

```sh
cd plugins/overlap-clip && swiftc *.swift -o overlap-clip
echo '{"protocolVersion":1,"files":[],"library":[{"path":"/Users/me/Pictures/x.jpg","kind":"image","tags":[],"modDate":"2024-01-01T00:00:00Z"}]}' \
  | OVERLAP_PLUGIN_CACHE=/tmp/oc ./overlap-clip          # downloads + indexes
echo '{"protocolVersion":1,"files":[],"library":[],"query":"a dog"}' \
  | OVERLAP_PLUGIN_CACHE=/tmp/oc ./overlap-clip          # → {"hits":[…]}
```
