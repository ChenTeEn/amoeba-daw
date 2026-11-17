(in-package #:score-prototype)

;; Each entry describes a way to work on the same revisioned project.
(defparameter *workspaces*
  '((:id "arrange" :view "panel" :commands ("status" "select B" "add-bars 2" "a" "b" "apply TOKEN" "undo REVISION")
     :next "Tempo and meter map; editable score and clip lanes.")
    (:id "record" :view "mix" :commands ("mix")
     :next "Wired take alignment and repeatable punch; multitrack arming and takes.")
    (:id "mix" :view "mix" :commands ("mix" "stems NEW-DIRECTORY" "undo REVISION")
     :next "Bus and send graph, stereo project metering and plugin hosting.")
    (:id "sound" :view nil :commands ("play B")
     :next "Lisp instrument and parameter graph with committed clips or deterministic renders.")
    (:id "live" :view nil :commands ("play B")
     :next "Persistent transport, quantized cues, MIDI mapping and a recoverable set.")))

(defun print-workspace (root &optional id)
  (let* ((project (project-state root))
         (session (score-session root))
         (rate (getf project :sample-rate))
         (revision (getf project :revision))
         (views (if id
                    (list (or (find id *workspaces* :key (lambda (row) (getf row :id)) :test #'equal)
                              (error "Choose arrange, record, mix, sound or live.")))
                    *workspaces*)))
    (format t "~A | REV ~D | section ~A | ~D Hz~%" (getf project :title) revision
            (or (first (selection root project)) "—") rate)
    (when (and (getf session :token) (eql revision (getf session :revision)))
      (format t "Pending edit: section ~A +~D bars~%" (getf session :section) (getf session :bars)))
    (format t "Capture alignment:~%")
    (dolist (route '(:internal :wired))
      (let ((profile (capture-profile route rate)))
        (format t "  ~(~A~)  ~A~%" route
                (if profile (format nil "~@D frames capture-window shift" (getf profile :window-shift))
                    "uncalibrated"))))
    (dolist (view views)
      (format t "~%~A~A~%" (string-upcase (getf view :id))
              (if (getf view :view) (format nil "  ·  :score ~A" (getf view :view)) "  ·  planned workspace"))
      (dolist (command (getf view :commands)) (format t "  :score ~A~%" command))
      (format t "  Next: ~A~%" (getf view :next)))))
