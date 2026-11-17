(defpackage #:amoeba-repl (:use #:cl) (:export #:daw))
(in-package #:amoeba-repl)

(defparameter *console*
  (merge-pathnames "score-console.lisp" (or *compile-file-truename* *load-truename*)))

(defun daw (project command &optional value)
  "Issue a named DAW command from SBCL without a browser."
  (sb-ext:process-exit-code
   (sb-ext:run-program (namestring sb-ext:*runtime-pathname*)
                        (append (list "--script" (namestring *console*) (namestring (pathname project))
                                      command)
                                (when value (list (princ-to-string value))))
                        :input nil :output t :error t)))
