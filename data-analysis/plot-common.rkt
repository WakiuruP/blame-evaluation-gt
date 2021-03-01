#lang at-exp rscript

(provide (contract-out
          [directory->blame-trails-by-mutator/across-all-benchmarks
           (path-to-existant-directory?
            #:summaries-db db:path-to-db?
            . -> .
            (hash/c string? (listof blame-trail?)))]
          [make-distributions-plots
           ({({string?
               (hash/c string? (listof blame-trail?))}
              {#:dump-to (or/c output-port? #f)}
              . ->* .
              pict?)
             #:breakdown-by (or/c "mutator" "benchmark")
             #:summaries-db db:path-to-db?
             #:data-directory path-to-existant-directory?}
            {#:dump-to-file (or/c path-string? boolean?)}
            . ->* .
            (hash/c string? pict?))]
          [make-distributions-table
           ({({string?
               (hash/c string? (listof blame-trail?))}
              {#:dump-to (or/c output-port? #f)}
              . ->* .
              pict?)
             #:breakdown-by (or/c "mutator" "benchmark")
             #:summaries-db db:path-to-db?
             #:data-directory path-to-existant-directory?}
            {#:dump-to-file (or/c path-string? boolean?)}
            . ->* .
            pict?)]
          [blame-reliability-breakdown-for
           (string?
            (hash/c string? (listof blame-trail?))
            . -> .
            (hash/c (or/c "always" "sometimes" "never")
                    (listof listof-blame-trails-for-same-mutant?)))]
          [satisfies-BT-hypothesis? (blame-trail? . -> . boolean?)]
          [add-missing-active-mutators
           ((hash/c mutator-name? (listof blame-trail?))
            . -> .
            (hash/c mutator-name? (listof blame-trail?)))]
          [two-sided-histogram
           ({(listof (list/c any/c real? real?))}
            {#:top-color any/c
             #:bot-color any/c
             #:gap any/c
             #:skip any/c
             #:add-ticks? boolean?}
            . ->* .
            list?)]
          [absolute-value-format (ticks? . -> . ticks?)])
         pict?
         add-to-list
         for/hash/fold)

(require plot
         plot-util
         plot-util/quick/infer
         (except-in pict-util line)
         (only-in pict vc-append text)
         pict-util/file
         "../mutation-analysis/mutation-analysis-summaries.rkt"
         "../experiment/blame-trail-data.rkt"
         (prefix-in db: "../db/db.rkt")
         "../configurables/configurables.rkt"
         "../runner/mutation-runner-data.rkt"

         "read-data.rkt"
         syntax/parse/define)

(define pict? any/c)
(define mutator-name? string?)

(define (directory->blame-trails-by-mutator/across-all-benchmarks
         data-dir
         #:summaries-db mutation-analysis-summaries-db)
  (define mutant-mutators
    (read-mutants-by-mutator mutation-analysis-summaries-db))

  (add-missing-active-mutators
   (read-blame-trails-by-mutator/across-all-benchmarks data-dir mutant-mutators)))

(define (make-distributions-plots make-distribution-plot
                                  #:breakdown-by breakdown-dimension
                                  #:summaries-db mutation-analysis-summaries-db
                                  #:data-directory data-dir
                                  #:dump-to-file [dump-path #f])
  (define blame-trails-by-mutator/across-all-benchmarks
    (directory->blame-trails-by-mutator/across-all-benchmarks
     data-dir
     #:summaries-db mutation-analysis-summaries-db))

  (define all-mutator-names (mutator-names blame-trails-by-mutator/across-all-benchmarks))

  (define dump-port (and dump-path
                         (open-output-file dump-path #:exists 'replace)))
  (define distributions
    (match breakdown-dimension
      ["mutator"
       (for/hash ([mutator (in-list all-mutator-names)])
         (when dump-port (newline dump-port) (displayln mutator dump-port))
         (define plot
           (make-distribution-plot mutator
                                   blame-trails-by-mutator/across-all-benchmarks
                                   #:dump-to dump-port))
         (values mutator plot))]
      ["benchmark"
       (define blame-trails-by-benchmark/across-all-mutators
         (for*/fold ([bts-by-benchmark (hash)])
                    ([{mutator bts} (in-hash blame-trails-by-mutator/across-all-benchmarks)]
                     [bt (in-list bts)])
           (define benchmark (mutant-benchmark (blame-trail-mutant-id bt)))
           (hash-update bts-by-benchmark
                        benchmark
                        (add-to-list bt)
                        empty)))
       (for/hash ([benchmark (in-hash-keys blame-trails-by-benchmark/across-all-mutators)])
         (when dump-port (newline dump-port) (displayln benchmark dump-port))
         (define plot
           (make-distribution-plot benchmark
                                   blame-trails-by-benchmark/across-all-mutators
                                   #:dump-to dump-port))
         (values benchmark plot))]))
  (when dump-port (close-output-port dump-port))
  distributions)

(define (make-distributions-table make-distribution-plot
                                  #:breakdown-by breakdown-dimension
                                  #:summaries-db mutation-analysis-summaries-db
                                  #:data-directory data-dir
                                  #:dump-to-file [dump-path #f])
  (define distributions
    (make-distributions-plots make-distribution-plot
                              #:breakdown-by breakdown-dimension
                              #:summaries-db mutation-analysis-summaries-db
                              #:data-directory data-dir
                              #:dump-to-file dump-path))
  (define distributions/sorted
    (map cdr (sort (hash->list distributions) string<? #:key car)))
  (table/fill-missing distributions/sorted
                      #:columns 3
                      #:column-spacing 5
                      #:row-spacing 5))

(define (add-missing-active-mutators blame-trails-by-mutator/across-all-benchmarks)
  (for/fold ([data+missing blame-trails-by-mutator/across-all-benchmarks])
            ([mutator-name (in-list (configured:active-mutator-names))])
    (hash-update data+missing
                 mutator-name
                 values
                 empty)))

(define (satisfies-BT-hypothesis? bt)
  (define end-mutant-summary (first (blame-trail-mutant-summaries bt)))
  (match end-mutant-summary
    [(mutant-summary _
                     (struct* run-status ([mutated-module mutated-mod-name]
                                          [outcome 'type-error]
                                          [blamed blamed]))
                     config)
     ;; Original definition, changed to any type error because any type error
     ;; should be good enough: see justification in notes
     #;(and (equal? (hash-ref config mutated-mod-name) 'types)
          (list? blamed)
          (member mutated-mod-name blamed))
     #t]
    [else #f]))

(define ((add-to-list v) l) (cons v l))

;; string? (hash/c string? (listof blame-trail?))
;; ->
;; (hash/c "always"    (listof (listof blame-trail?))
;;         "sometimes" ^
;;         "never"     ^)
(define (blame-reliability-breakdown-for key
                                         blame-trail-map)
  (define trails (hash-ref blame-trail-map key))
  (define total-trail-count (length trails))
  (define trails-grouped-by-mutant (group-by blame-trail-mutant-id trails))

  (define (categorize-trail-set-reliability trail-set)
    (define bt-success-count (count satisfies-BT-hypothesis? trail-set))
    (match* {bt-success-count (length trail-set)}
      [{     0  (not 0)}                 "never"]
      [{s       n      } #:when (= s n)  "always"]
      [{(not 0) (not 0)}                 "sometimes"]))

  (for/fold ([breakdown (hash "always" empty
                              "sometimes" empty
                              "never" empty)])
            ([mutant-trails (in-list trails-grouped-by-mutant)])
    (define mutant-category (categorize-trail-set-reliability mutant-trails))
    (hash-update breakdown
                 mutant-category
                 (add-to-list mutant-trails))))

(define (listof-blame-trails-for-same-mutant? l)
  (and (list? l)
       (andmap blame-trail? l)
       (cond [(empty? l) #t]
             [else
              (define mutant (blame-trail-mutant-id (first l)))
              (for/and ([bt (in-list l)])
                (equal? (blame-trail-mutant-id bt)
                        mutant))])))

(define-simple-macro (for/hash/fold for-clauses
                                    {~optional {~seq #:init initial-hash}
                                               #:defaults ([initial-hash #'(hash)])}
                                    #:combine combine
                                    #:default default
                                    body ...)
  (for/fold ([result-hash initial-hash])
            for-clauses
    (define-values {key value} (let () body ...))
    (hash-update result-hash
                 key
                 (λ (accumulator) (combine value accumulator))
                 default)))

; See ctc above
(define (two-sided-histogram data
                             #:top-color [top-color (rectangle-color)]
                             #:bot-color [bot-color (rectangle-color)]
                             #:gap [gap (discrete-histogram-gap)]
                             #:skip [skip (discrete-histogram-skip)]
                             #:add-ticks? [add-ticks? #t])
  (list (discrete-histogram (map (match-lambda [(list name top _) (list name top)])
                                 data)
                            #:color top-color
                            #:gap gap
                            #:skip skip
                            #:add-ticks? add-ticks?)
        ;; lltodo: this is a workaround for a bug with discrete-histogram
        ;; This doesn't work:
        #;(plot (list (discrete-histogram '((a 5) (b 3)))
                         (discrete-histogram '((a -2) (b -4)))
                         (x-axis))
                   #:y-min -5)
        ;; while this does:
        #;(plot (list (discrete-histogram '((a 5) (b 3)))
                         (discrete-histogram '((a -2)) #:x-min 0)
                         (discrete-histogram '((b -4)) #:x-min 1)
                         (x-axis))
                   #:y-min -5)
        (for/list ([bar-sides (in-list data)]
                   [i (in-naturals)])
          (match-define (list name _ bottom) bar-sides)
          (discrete-histogram `((,name ,(- bottom)))
                              #:x-min i
                              #:color bot-color
                              #:gap gap
                              #:skip skip
                              #:add-ticks? add-ticks?))))

; See ctc above
(define (absolute-value-format original-ticks)
  (ticks (ticks-layout original-ticks)
         (λ (min max ticks)
           (define absolute-value-ticks
             (for/list ([tick (in-list ticks)])
               (struct-copy pre-tick tick
                            [value (abs (pre-tick-value tick))])))
           ((ticks-format original-ticks) min max absolute-value-ticks))))