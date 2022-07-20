#lang racket/base

(require "../configurables.rkt"
         "blame-following-common.rkt")

(provide install!)

(define (install!)
  (configure! mutation                 type-mistakes-in-code)
  (configure! mutant-sampling          none)
  (configure! mutant-filtering         select-type-erroring-max-config-mutants)
  (configure! module-selection-for-mutation all-regular-modules)
  (configure! module-instrumentation   none)
  (configure! benchmark-runner         run-it)
  (configure! blame-following          pick-some
              ; runtime-error-with-blame
              select-all-blamed
              ; runtime-error
              select-top-of-errortrace/context-fallback
              ; blame
              select-all-blamed)
  (configure! bt-root-sampling         random-with-replacement)
  (configure! trail-completion         any-type-error/blamed-at-max)
  (configure! configurations           module-types)

  (configure! program-instrumentation  just-instrument-modules))