# GigaAM v3 CoreML Update

## Что изменилось

GigaAM v3 в Muesli/Guesli переведен с MLX Swift runtime на precompiled CoreML backend.

Удалено:

- SwiftPM dependency `https://github.com/kruatech/gigaam-v3-mlx.git`
- product dependency `GigaAMKit`
- transitive MLX runtime pin `mlx-swift`
- runtime staging `mlx.metallib` / `mlx-swift_Cmlx.bundle` из benchmark flow

Оставлено намеренно:

- `backend = "gigaam_v3"` как стабильный app/config id
- legacy model alias `kruatech/gigaam-v3-mlx` -> новый CoreML backend
- два tiny frontend asset файла из старого model repo:
  - `hann_window.f32.bin`
  - `mel_filterbank_mel_freq.f32.bin`

Эти два файла не MLX runtime и не MLX weights. Это входной mel frontend, меньше 50 KB суммарно. Значения там уже округлены не как обычная float32 формула, поэтому безопаснее брать точные assets, чем генерировать похожие и ловить тихую деградацию качества.

## Новая модель

Новый model id:

```text
huggingfinger0/gigaam-v3-coreml
```

Новый cache path:

```text
Models/gigaam-v3-coreml
```

Required files теперь CoreML bundles:

- `Encoder.mlmodelc`
- `Predictor.mlmodelc`
- `JointDecision.mlmodelc`
- `vocab.txt`
- `hann_window.f32.bin`
- `mel_filterbank_mel_freq.f32.bin`

Размер UI label: `~224 MB` вместо `~445 MB`.

## Логика inference

CoreML GigaAM v3 остается RNNT model, не CTC.

Pipeline:

1. Audio приводится к 16 kHz mono через существующий `AudioFileImportController`.
2. Long audio режется app-level chunker-ом:
   - threshold: `25s`
   - window: `20s`
   - overlap: `2s`
3. На каждый chunk считается GigaAM-compatible mel spectrogram:
   - `n_mels = 64`
   - `n_fft = 320`
   - `win_length = 320`
   - `hop_length = 160`
   - `center = false`
4. CoreML encoder получает padded features `[1, 64, 3000]`.
5. RNNT decode идет через:
   - `Encoder.mlmodelc`
   - `Predictor.mlmodelc`
   - `JointDecision.mlmodelc`
6. Blank token: `1024`.
7. На frame разрешено до 10 emitted tokens.
8. Chunk transcripts merge-ятся старым suffix/prefix overlap merge.

Важно: 607-second recordings больше не передаются в модель одним файлом. Для полного meeting smoke было `34 windows`, max window `20s`.

## Почему не FluidAudio flow напрямую

FluidAudio уже остается для Parakeet/SenseVoice/etc. Но GigaAM CoreML bundle другой:

- Parakeet flow завязан на TDT/FluidAudio `AsrManager`
- GigaAM CoreML bundle RNNT-style: encoder + predictor + joint
- нужны GigaAM frontend assets и свой decode loop

Пихать GigaAM внутрь FluidAudio без полноценного нового manager-а было бы больше кода и риска. Минимальный рабочий путь: CoreML runner в текущем `gigaam_v3` backend.

## Почему не pyannote longform

GigaAM Python `transcribe_longform` полезен как идея, но не как app dependency.

Он решает long-form через segmentation/VAD:

1. pyannote режет речь на сегменты
2. каждый сегмент гонится через обычный `.transcribe`

Минусы для Guesli:

- Python dependency stack
- HF token
- gated `pyannote/segmentation-3.0`
- отдельная модель и условия доступа
- плохо ложится в sandboxed macOS app

Что стоит сделать потом: заменить fixed 20s windows на native VAD/speech-boundary chunker через уже имеющийся CoreML/FluidAudio путь. Не сейчас: текущий fixed chunker уже закрывает 25s limit и long-form crash.

## Совместимость

Старые настройки могли хранить:

```text
backend = gigaam_v3
model = kruatech/gigaam-v3-mlx
```

Теперь `BackendOption.resolve(...)` мапит этот pair на CoreML GigaAM. `MuesliController` тоже использует `BackendOption.resolve(...)` для стартового selected backend, так что старый config не должен падать в fallback.

## Проверка

Targeted contract test:

```bash
swift test --package-path native/MuesliNative \
  --scratch-path /private/tmp/muesli-spm-coreml-prod \
  --filter BackendOptionTests/gigaAMV3
```

Итог:

```text
3 tests passed
```

Short production smoke:

```text
meeting 17
audio: 30.000s
windows: 2
transcribe: 23.890s
total: 36.485s
status: ok
```

Full long-form production smoke:

```text
meeting 2
audio: 607.061s
windows: 34
maxWindow: 20.000s
overlap: 2.000s
transcribe: 495.421s
total: 495.568s
RTF: 0.816
speed: 1.225x
status: ok
```

Previous MLX full run on same 607s recording:

```text
total: 646.104s
RTF: 1.064
speed: 0.94x
```

Observed result:

- CoreML full run passed without CoreML IOSurface/OOM crash.
- CoreML was about 23% faster than previous MLX full run on this recording.
- SwiftPM build no longer fetches `gigaam-v3-mlx` or `mlx-swift`.

## Current caveat

RNNT decode is still sequential. CoreML removes MLX dependency and is faster here, but it will not reach Parakeet speed unless model/export changes or decode loop changes. Parakeet is faster mostly because FluidAudio Parakeet path is optimized around its own CoreML/TDT runtime and skips/handles chunks differently.
