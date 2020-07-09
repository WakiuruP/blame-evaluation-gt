#lang at-exp racket/base

(require "../util/optional-contracts.rkt"
         (except-in racket/contract/base
                    contract-out))

(provide (contract-out
          [expression-selector/c contract?]
          [select-any-expr expression-selector/c]
          [select-exprs-as-if-untyped expression-selector/c]))

(require racket/bool
         racket/format
         racket/function
         racket/list
         syntax/parse)

(define expression-selector/c
  (syntax?
   . -> .
   (or/c #f
         (list/c syntax?
                 (syntax? . -> . syntax?)
                 (listof (cons/c parameter? any/c))))))

(define (select-any-expr expr)
  (list expr
        identity
        empty))

(define-splicing-syntax-class type-annotation
  #:datum-literals [:]
  #:attributes [(annotation-parts 1)]
  [pattern {~seq : T}
           #:with [annotation-parts ...] #'[: T]]
  [pattern (: e ...)
           #:with [annotation-parts ...] #'[(: e ...)]])

;; If `expr` contains no type annotation subexprs, select the expr as-is.
;; If `expr` contains type annotations, select all subexprs of `expr` not
;; associated with the type annotations; the reconstructor puts the annotations
;; back in.
;;
;; ASSUMPTION: the reconstructor assumes that the syntax it receives will have
;; the same number of subexprs as the selected syntax.
;;
;; Example:
;; (+ 2 (apply (λ (x) x) 42))
;;   selects everything, and the reconstructor is identity
;; (+ 2 (apply (λ ([x : Natural]) : Natural x) 42))
;;   same as above
;; (ann (+ 2 (apply (λ ([x : Natural]) : Natural x) 42)) T)
;;   selects the inner expr, and the reconstructor puts the `(ann ... T)` back
;; (for : T (...) foobar)
;;   selects (for (...) foobar), and the reconstructor puts the `: T` back
(define (select-exprs-as-if-untyped expr)
  (syntax-parse expr
    #:datum-literals [: ann cast inst row-inst quote quasiquote]
    [(: . _) #f]
    [({~and the-annotation-thing
            {~or ann
                 cast
                 inst
                 row-inst}}
      e
      T ...)
     (list #'e
           (λ (new-e)
             (quasisyntax/loc expr
               (the-annotation-thing #,new-e T ...)))
           empty)]
    [({~and e-1 {~not {~or* : (: . _)}}}
      ...+
      {~seq annot:type-annotation
            {~and e-i {~not {~or* : (: . _)}}} ...}
      ...+)
     (define e-1-count (length (attribute e-1)))
     (define e-i-counts (map length (attribute e-i)))
     (list
      #'(e-1 ... {~@ e-i ...} ...)
      (λ (mutated-stx)
        (define mutated-stx-parts (syntax->list mutated-stx))
        (define (flexible-split-at l index)
          (if (> index (length l))
              (values l empty)
              (split-at l index)))
        (define-values {mutated-e-1s remaining-stx-parts}
          (flexible-split-at mutated-stx-parts e-1-count))
        (define mutated-e-is
          (for/fold ([remaining-stx-parts remaining-stx-parts]
                     [mutated-e-is empty]
                     #:result (reverse mutated-e-is))
                    ([e-i-count (in-list e-i-counts)]
                     [e-i-group-index (in-naturals)])
            (define-values {e-is now-remaining-stx}
              (if (= e-i-group-index (sub1 (length e-i-counts)))
                  (values remaining-stx-parts empty)
                  (flexible-split-at remaining-stx-parts e-i-count)))
            (values now-remaining-stx
                    (cons e-is mutated-e-is))))
        (with-syntax ([[mutated-e-1 ...] mutated-e-1s]
                      [[[mutated-e-i ...] ...] mutated-e-is])
          (syntax/loc expr
            (mutated-e-1
             ...
             {~@ annot.annotation-parts ... mutated-e-i ...}
             ...))))
      empty)]
    ;; ll: this is a bit naive, see tests below for #''(: a b c)
    [{~or* ({~or* quote quasiquote} atom)
           atom
           ({~and e-1 {~not :}} ...)}
     #:when (or (not (attribute atom))
                (false? (syntax->list #'atom)))
     (list this-syntax
           identity
           empty)]
    [other
     (error 'select-exprs-as-if-untyped
            @~a{Syntax @#'other doesn't match any patterns.})]))

(module+ test
  (require ruinit
           racket
           "mutate-test-common.rkt")
  (define-test (test-selector selector
                              stx
                              expected
                              [params-test (const #t)])
    (define result (selector stx))
    (match* {result expected}
      [{(list new-stx reconstructor params) (not #f)}
       (and/test (test-programs-equal? new-stx expected)
                 (test-programs-equal? (reconstructor new-stx) stx)
                 (params-test params))]
      [{(not #f) #f}
       (fail @~a{Selector matches with result: @result})]
      [{#f (not #f)}
       (fail @~a{Selector does not match when it should.})]
      [{#f #f} #t]))
  (test-begin
    #:name select-exprs-as-if-untyped
    (test-selector select-exprs-as-if-untyped
                   #'x
                   #'x)
    (test-selector select-exprs-as-if-untyped
                   #'42
                   #'42)
    (test-selector select-exprs-as-if-untyped
                   #'()
                   #'())
    (test-selector select-exprs-as-if-untyped
                   #'(: a T)
                   #f)
    (test-selector select-exprs-as-if-untyped
                   #'(ann x T)
                   #'x)
    (test-selector select-exprs-as-if-untyped
                   #'(cast x T)
                   #'x)
    (test-selector select-exprs-as-if-untyped
                   #'(inst x T1 T2)
                   #'x)
    (test-selector select-exprs-as-if-untyped
                   #'(row-inst x T1 T2 T3)
                   #'x)
    (test-selector select-exprs-as-if-untyped
                   #'(f a b 42 c)
                   #'(f a b 42 c))
    (test-selector select-exprs-as-if-untyped
                   #'[a : Natural 42]
                   #'[a 42])
    (test-selector select-exprs-as-if-untyped
                   #'(λ ([x : T]) : R (+ 2 2))
                   #'(λ ([x : T]) (+ 2 2)))
    (test-selector select-exprs-as-if-untyped
                   #'(for : T ([v : Boolean (in-list bools)])
                          (displayln v))
                   #'(for ([v : Boolean (in-list bools)])
                       (displayln v)))
    (test-selector select-exprs-as-if-untyped
                   #'(define (f [x : T]) : R (+ x 2))
                   #'(define (f [x : T]) (+ x 2)))
    (test-selector select-exprs-as-if-untyped
                   #'(define (f [x : T]) (: y R) (+ x 2))
                   #'(define (f [x : T]) (+ x 2)))
    (test-selector select-exprs-as-if-untyped
                   #'(define x ':)
                   #'(define x ':))
    (test-selector select-exprs-as-if-untyped
                   #'':
                   #'':)
    (test-selector select-exprs-as-if-untyped
                   #'`:
                   #'`:)
    (test-selector select-exprs-as-if-untyped
                   #'(quote :)
                   #'(quote :))
    ;; Note that the simple handling of the above makes this sort of thing
    ;; happen. For now as long as we can reconstruct the sexp I'm going to say
    ;; it's fine.
    (test-selector select-exprs-as-if-untyped
                   #''(: a b c)
                   #'(quote)))

  (test-begin
    #:name select-exprs-as-if-untyped/reconstructor
    (ignore (match-define (list selected reconstruct params)
              (select-exprs-as-if-untyped #'(+ 2 2))))
    (test-programs-equal? (reconstruct #'(- 2 2))
                          #'(- 2 2)))

  (test-begin
    #:name select-exprs-as-if-untyped/reconstruct/add-remove-swap-exprs
    ;; swap
    (ignore (match-define (list selected reconstruct params)
              (select-exprs-as-if-untyped #'(begin x : T y (: x T2) z))))
    (test-programs-equal? (reconstruct #'(begin x y))
                          #'(begin x : T y (: x T2)))
    (test-programs-equal? (reconstruct #'(begin x z y))
                          #'(begin x : T z (: x T2) y))
    ;; add
    (ignore (match-define (list selected reconstruct params)
              (select-exprs-as-if-untyped #'(class parent
                                              (field a b c)
                                              (: f : Number -> Number)
                                              (define/public (f x) x)))))
    (test-programs-equal? (reconstruct
                           #'(class parent
                               (define/public (a-nonexistant-method x) x)
                               (field a b c)
                               (define/public (f x) x)))
                          #'(class parent
                              (define/public (a-nonexistant-method x) x)
                              (: f : Number -> Number)
                              (field a b c)
                              (define/public (f x) x)))
    ;; remove
    (ignore (match-define (list selected reconstruct params)
              (select-exprs-as-if-untyped #'(class parent
                                              (field a b c)
                                              (super-new)
                                              (: f : Number -> Number)
                                              (define/public (f x) x)))))
    (test-programs-equal? (reconstruct
                           #'(class parent
                               (field a b c)
                               (define/public (f x) x)))
                          #'(class parent
                              (field a b c)
                              (define/public (f x) x)
                              (: f : Number -> Number))))

  (require "../util/for-first-star.rkt")
  (test-begin
    #:name select-exprs-as-if-untyped/random-testing
    (not (for/first* ([i (in-range 1000)])
                     (define random-stx-datum
                       (contract-random-generate (listof symbol?) 1))
                     (define stx
                       (datum->syntax #f random-stx-datum))
                     (define seems-untyped? (member ': random-stx-datum))
                     (and seems-untyped?
                          (test-fail? (test-selector select-exprs-as-if-untyped
                                                     stx
                                                     stx))
                          random-stx-datum)))))