# Nemotron 3.5 CoreML padded-strides bug

## Симптом

В UI модель `Nemotron 3.5 Multilingual` могла быть скачана и выбрана как активная,
но короткий smoke-run падал уже после загрузки CoreML-моделей:

```text
Decoding failed: encoded shape [1, 1024, 28] and strides [32768, 32, 1] exceed backing count 28672
```

Перед этим CoreML мог писать в stderr нефатальное предупреждение про shape inference:

```text
E5RT encountered an STL exception ... zero shape error
```

Это не означало, что модели нет в текущем билде. Базовый Nemotron уже есть в
upstream `origin/main`; локальный `main` дополнительно содержит форк-guard
`89926a3c Prevent Nemotron layout traps from bad models`.

## Причина

Guard в `NemotronRNNTEngine.swift` считал, что максимальный offset, достижимый
через `MLMultiArray.strides`, обязан быть меньше `MLMultiArray.count`.

Для CoreML это неверное допущение:

- `MLMultiArray.count` - логическое число элементов по shape;
- CoreML может вернуть padded/non-contiguous layout;
- strides описывают валидное расположение в backing memory;
- у такого массива последний stride-offset может быть больше logical `count`.

На реальном выходе encoder:

```text
shape   = [1, 1024, 28]
strides = [32768, 32, 1]
count   = 28672
```

Logical count равен `1024 * 28 = 28672`, но stride layout читает frame-major
данные с padding. Такой layout нормален для CoreML и совпадает с тем, как
FluidAudio читает encoder output: по shape/strides, без сравнения с `count`.

## Фикс

Валидатор `nemotronValidateArray` теперь:

- продолжает проверять dtype, rank, ожидаемые размеры и положительные strides;
- считает `storageSpan = maxStrideOffset + 1`;
- не отвергает padded CoreML layouts только потому, что `storageSpan > count`;
- возвращает `storageSpan` вызывающему коду.

Чтение `mel` и `encoded` теперь bind-ит указатель с capacity `storageSpan`, а не
logical `array.count`. Это соответствует фактическому stride-access pattern:

```swift
encFramePtr[d] = encodedPtr[d * encodedStride1 + t * encodedStride2]
```

Добавлен regression-test `encoded validation accepts CoreML padded strides`,
который создает `MLMultiArray` с shape `[1, 4, 3]`, strides `[64, 4, 1]` и
logical count `12`, но валидным `storageSpan = 15`.

## Важное про входные файлы

`m4a` здесь не ASR input format. В Muesli/Guesli это компактный формат хранения.
Для проверки самого Nemotron фикс нужно гонять после штатного decode/import в PCM
или на уже готовом WAV/PCM, иначе тест смешивает баг ASR runtime с контейнером
хранения записи.

## Проверка

Минимальная проверка формы:

```bash
swift test --package-path native/MuesliNative \
  --scratch-path /private/tmp/muesli-spm-nemotron-smoke \
  --filter NemotronRNNTShapeGuardTests
```

Smoke-проверка runtime на PCM/WAV:

```bash
env MUESLI_ASR_BENCH=1 \
  MUESLI_ASR_BENCH_RECORDINGS="/Users/kiwi/Library/Application Support/Muesli/meeting-recordings/2026-06-15-11-59-43-обсуждение-пэймент-тайпа.wav" \
  MUESLI_ASR_BENCH_MAX_SECONDS=8 \
  MUESLI_ASR_BENCH_MODELS=nemotron35 \
  MUESLI_ASR_BENCH_ALLOW_DOWNLOADS=0 \
  swift test --package-path native/MuesliNative \
    --scratch-path /private/tmp/muesli-spm-nemotron-smoke \
    --filter ASRModelEfficiencyBenchmarks/compareProductionASRModelsOnRealRecordings
```

Фактический результат после фикса на 8 секундах WAV:

```text
[muesli-native] Nemotron 3.5 warmup complete
[muesli-native] Nemotron 3.5 result: Здорово! Привет! (took 0.651s)
| nemotron35 | - | ok | 8.000 | 2.067 | 0.258 | 3.870 | - | - | 910.266 | quality skipped: sliced audio without timed reference |
```

E5RT warning про `ios17.slice_by_index: zero shape error` все еще может появляться
после успешного результата, но после фикса он не превращается в runtime-failure.
