#lang at-exp rscript

(require "../configurables/configurables.rkt"
         (submod "../experiment/mutant-factory.rkt" test)
         "../experiment/mutant-factory-data.rkt"
         "../configurations/configure-benchmark.rkt"
         "mutant-util.rkt")

(define-runtime-paths
  [configs-dir "../configurables"])

(define (guess-path . parts)
  (define path (apply build-path parts))
  (if (or (path-to-existant-directory? path)
          (path-to-existant-file? path))
      path
      (raise-user-error 'guess-path
                        @~a{Unable to infer a necessary path. Guessed: @path})))

(define (infer-benchmark log-path)
  (define benchmark-path
    (match (system/string @~a{grep -E 'Running on benchmark' @log-path})
      [(regexp #px"(?m:Running on benchmark (.+)$)" (list _ path))
       #:when (path-to-existant-directory? path)
       path]
      [(regexp #px"(?m:Running on benchmark (.+)$)" (list _ path))
       (displayln @~a{path-to-existant-directory? of @(simple-form-path path) => @(path-to-existant-directory? path)})
       (exit 1)]
      [other
       (displayln @~a{Got other: @other})
       (raise-user-error
        'check-experiment-progress
        "Unable to infer benchmark path. Are you running from the same directory the experiment was run?")]))
  (read-benchmark benchmark-path))

(define (infer-configuration log-path)
  (match (system/string @~a{grep -E 'Running experiment with config' @log-path})
    [(regexp #rx"(?m:config (.+)$)" (list _ path))
     #:when (path-to-existant-file? path)
     path]
    [(regexp #rx"(?m:config .+/(.+)$)" (list _ config-name))
     #:when (path-to-existant-file? (build-path configs-dir config-name))
     (build-path configs-dir config-name)]
    [else
     (raise-user-error 'check-experiment-progress
                       "Unable to infer path to config for this experiment.")]))

(define (all-mutants-for bench)
  (define select-mutants
    (load-configured (current-configuration-path)
                     "mutant-sampling"
                     'select-mutants))
  (for*/list ([module-to-mutate-name (in-list (benchmark->mutatable-modules bench))]
              [mutation-index (select-mutants module-to-mutate-name bench)])
    (mutant module-to-mutate-name mutation-index #t)))

(define (check-progress-percentage progress-log-path all-mutants)
  (define progress (file->list progress-log-path))
  (/ (length progress)
     (* (sample-size) (length all-mutants))))

(define (progress-bar-string % #:width width)
  (define head-pos (inexact->exact (round (* % width))))
  (define before-head (make-string head-pos #\=))
  (define after-head (make-string (- width head-pos) #\space))
  (~a before-head ">" after-head))

(define (format-updating-display #:width width . parts)
  (define full (apply ~a parts))
  (define len (string-length full))
  (define remaining (- width len))
  (if (negative? remaining)
      (~a (substring full 0 (- width 3)) "...")
      (~a full (make-string remaining #\space))))

(define (truncate-string-to str chars)
  (if (<= (string-length str) chars)
      str
      (substring str 0 chars)))

(main
 #:arguments {[(hash-table ['watch watch-mode?])
               (list benchmark-dir)]
              #:once-each
              [("-w" "--watch")
               'watch
               ("Interactively show a progress bar that updates every 5 sec.")
               #:record]
              #:args [benchmark-dir]}
 #:check [(path-to-existant-directory? benchmark-dir)
          @~a{Unable to find @benchmark-dir}]

 (define log-path
   (guess-path benchmark-dir (~a (basename benchmark-dir) ".log")))
 (define bench (infer-benchmark log-path))

 (current-configuration-path (infer-configuration log-path))
 (define all-mutants (all-mutants-for bench))

 (define progress-log-path
   (guess-path benchmark-dir (~a (basename benchmark-dir) "-progress.log")))

 (cond [watch-mode?
        (define period 5)
        (define start-time (current-inexact-milliseconds))
        (define start-% (check-progress-percentage progress-log-path
                                                   all-mutants))
        (let loop ()
          (define % (check-progress-percentage progress-log-path
                                               all-mutants))
          (define pretty-%
            (truncate-string-to (~a (* (/ (truncate (* % 1000)) 1000.0) 100))
                                4))
          (define completion-rate:%/s
            (/ (- % start-%)
               (/ (match (- (current-inexact-milliseconds)
                            start-time)
                    [0 +inf.0]
                    [not-0 not-0])
                  1000.0)))
          (define remaining-% (- 1 %))
          (define remaining-time-estimate
            (if (zero? completion-rate:%/s)
                0
                (inexact->exact (round (/ (/ remaining-% completion-rate:%/s) 60.0)))))
          (display
           (format-updating-display
            #:width 80
            @~a{[@(progress-bar-string % #:width 50)] @|pretty-%|%}
            " "
            remaining-time-estimate
            " min left"))
          (display "\r")
          (unless (= % 1)
            (sleep period)
            (loop)))]
       [else
        (displayln (exact->inexact (check-progress-percentage progress-log-path
                                                              all-mutants)))]))