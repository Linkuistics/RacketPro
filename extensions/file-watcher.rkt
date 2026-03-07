#lang racket/base

(require racket/list
         "../racket/heavymental-core/extension.rkt"
         "../racket/heavymental-core/cell.rkt")

(define-extension file-watcher-ext
  #:name "File Watcher"
  #:cells ([recent-changes (list)])
  #:panels ([#:id "watcher" #:label "Changes" #:tab 'bottom
             #:layout (hasheq 'type "vbox"
                              'props (hasheq 'flex "1")
                              'children
                              (list
                               (hasheq 'type "text"
                                       'props (hasheq 'text "cell:recent-changes")
                                       'children (list))))])
  #:on-activate
  (lambda ()
    (define root (cell-ref 'project-root))
    (when (and (string? root) (not (string=? root "")))
      (watch-directory! root
        (lambda (event path)
          (cell-update! 'file-watcher-ext:recent-changes
            (lambda (lst)
              ;; Keep last 20 changes
              (take (cons (format "~a: ~a" event path) lst)
                    (min 20 (add1 (length lst))))))))))
  #:on-deactivate
  (lambda ()
    (unwatch-all!)))

(provide (rename-out [file-watcher-ext extension]))
