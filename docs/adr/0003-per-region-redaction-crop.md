# Redactions crop the region before filtering

Blur and pixelate redactions (`Annotation.swift`) crop the captured image to the annotated rect and run `CIContext`/`CIFilter` only on that crop, instead of filtering the full captured image. A full-frame `CIContext` pass was tried first and silently fails — produces no output, with no error — on large or multi-display captures; there is no error signal to catch, so a future "simplification" back to full-frame filtering would quietly break redaction on big screens without anyone noticing until a screenshot leaked.

## Amendment (phase 6, beautify-effects)

Image effects are subject to the same rule for the same reason. The brightness/contrast/saturation/sharpness pass runs on the Selection crop only — never on the whole frozen screen image — at a bounded working size for the live preview and once at full resolution at bake time. Every Core Image render is nil-checked and falls back to the unfiltered image with a log entry, because the failure mode here is silence: an unchecked optional would ship a screenshot that quietly ignored the user's settings. The large-image regression test asserts on content rather than on the absence of a thrown error, for the same reason.
