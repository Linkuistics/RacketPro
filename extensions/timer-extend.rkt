#lang heavymental/extend

(name: "Timer")

(cell elapsed = 0)
(cell running = #f)

(panel timer "Timer" bottom
  (vbox
    (text #:content "cell:elapsed")
    (hbox
      (button #:label "Start" #:on-click "start")
      (button #:label "Stop" #:on-click "stop")
      (button #:label "Reset" #:on-click "reset"))))

(event start
  (cell-set! 'timer:running #t))

(event stop
  (cell-set! 'timer:running #f))

(event reset
  (begin
    (cell-set! 'timer:running #f)
    (cell-set! 'timer:elapsed 0)))

(on-activate (displayln "Timer extension loaded"))
(on-deactivate (displayln "Timer extension unloaded"))
