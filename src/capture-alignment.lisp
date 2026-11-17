(in-package #:score-prototype)

;; The public preview has no calibration data. A separate measured-route
;; profile format can be added without changing the score or take model.
(defun capture-profile (route rate)
  (declare (ignore route rate))
  nil)

(defun capture-window-shift (route rate)
  (declare (ignore route rate))
  0)
