% Annotate final SVG glyphs so resource coordinates come from the actual engraving.
#(define (anchor-engraver context)
  (define (mark grob kind)
    (ly:grob-set-property! grob 'output-attributes
      (list (cons 'data-kind kind) (cons 'data-tick (number->string
        (ly:moment-main (ly:moment-mul (ly:context-current-moment context) (ly:make-moment 3840))))))))
  (make-engraver
    (acknowledgers
      ((note-head-interface engraver grob source-engraver) (mark grob "note"))
      ((rest-interface engraver grob source-engraver) (mark grob "rest"))
      ((bar-line-interface engraver grob source-engraver) (mark grob "bar")))))
