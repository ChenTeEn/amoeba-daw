(load (merge-pathnames "score.lisp" *load-truename*))
(in-package #:score-prototype)
(load (merge-pathnames "score-audio.lisp" *source-directory*))

(defun selection-file (root)
  (project-file root "selection.sexp"))

(defun score-session (root)
  (let ((path (probe-file (selection-file root))))
    (when path (read-data path))))

(defun selection (root project)
  (assoc (getf (score-session root) :section) (getf project :sections) :test #'equal))

(defun select-section (root id &optional revision)
  (call-with-project-lock
   root
   (lambda ()
     (let* ((project (project-state root))
            (section (assoc id (getf project :sections) :test #'string-equal)))
       (when revision (assert-revision project revision))
       (unless section (error "Section ~A is not in this project." id))
       (unless (eq section (selection root project))
         (write-data (selection-file root) (list :section (first section))))
       section))))

(defun score-nonce ()
  (with-open-file (stream "/dev/urandom" :element-type '(unsigned-byte 8))
    (format nil "~(~{~2,'0X~}~)" (loop repeat 16 collect (read-byte stream)))))

(defun preview-selected-edit (root bars)
  (call-with-project-lock
   root
   (lambda ()
     (let* ((project (project-state root))
            (id (first (selection root project))))
       (unless id (error "Choose a section on the score or use :score select B."))
       (let* ((plan (preview-state project id bars))
              (token (subseq (score-nonce) 0 12)))
         (setf (getf plan :confirmation) token)
         (write-data (selection-file root)
                     (list :section id :revision (getf project :revision) :bars bars :token token))
         plan)))))

(defun confirm-selected-edit (root token)
  (call-with-project-lock
   root
   (lambda ()
     (let* ((project (project-state root))
            (session (score-session root)))
       (unless (and (equal token (getf session :token))
                    (eql (getf project :revision) (getf session :revision)))
         (error "Preview again. This token is absent, replaced or from a different revision."))
       (commit-insertion root project
                         (preview-state project (getf session :section) (getf session :bars)))))))

(defun list-sections (root)
  (let* ((project (project-state root))
         (selected (selection root project)))
    (format t "~A | revision ~D | selected ~A~%" (getf project :title)
            (getf project :revision) (or (first selected) "none"))
    (loop with bar = 1 for entry in (getf project :sections)
          do (format t "  ~A ~A | bars ~D–~D (~D)~%" (if (eq entry selected) "*" " ")
                     (first entry) bar (+ bar (second entry) -1) (second entry))
             (incf bar (second entry)))))

(defun audition-spec (root mode)
  (call-with-project-lock
   root
   (lambda ()
     (let* ((base (project-state root))
            (session (score-session root))
            (id (first (selection root base))))
       (unless id (error "Choose a section first."))
       (unless (audition-data root) (error "This project has no audition instrument data."))
       (when (and (member mode '("a" "b") :test #'equal)
                  (not (and (eql (getf session :revision) (getf base :revision))
                            (getf session :token))))
         (error "Use :score add-bars to preview an edit before A/B."))
       (multiple-value-bind (from to) (audition-window base id (not (equal mode "play")))
         (list (if (equal mode "b")
                   (project-insertion base (preview-state base id (getf session :bars)))
                   base)
               from to))))))

(defun start-score-playback (root mode)
  (destructuring-bind (project from to) (audition-spec root mode)
    (format t "~&~A | beats ~D–~D | ~D Hz stereo, project gain~%" (string-upcase mode) from to (getf project :sample-rate))
    (start-audition root project from to)))

(load (merge-pathnames "capture-alignment.lisp" *source-directory*))
(load (merge-pathnames "score-workspace.lisp" *source-directory*))

(load (merge-pathnames "score-session.lisp" *source-directory*))

(defun score-command (root args)
  (destructuring-bind (&optional command value &rest extra) args
    (when extra (error "Too many arguments."))
    (cond ((member command '("serve" "session" "at" "stop" "seek" "jump" "play" "mix") :test #'equal)
           (session-command root command value))
          ((equal command "work") (print-workspace root value))
          ((and (member command '(nil "status") :test #'equal) (not value))
           (list-sections root))
          ((and (equal command "select") value)
           (format t "Selected section ~A.~%" (first (select-section root value))))
          ((and (equal command "add-bars") value)
           (print-plan (preview-selected-edit root (parse-integer value))))
          ((and (equal command "apply") value)
           (format t "Applied revision ~D. Undo with :score undo REVISION.~%"
                   (confirm-selected-edit root value)))
          ((and (equal command "undo") value)
           (format t "Restored content as revision ~D.~%" (rollback root (parse-integer value))))
          ((and (member command '("a" "b") :test #'equal)
                (or (not value) (equal command "play")))
           (when value (select-section root value))
           (let ((audio (start-score-playback root command)))
             (unwind-protect
                  (unless (zerop (finish-audition audio))
                    (error "Playback failed. Check the project's output and other active audio routes."))
               (finish-audition audio t))))
          ((and (equal command "stems") value)
           (let ((project (project-state root)))
             (format t "Exported revision ~D to ~A~%" (getf project :revision)
                     (export-stems root project (project-file root value)))))
          ((and (equal command "panel") (not value))
           (load (merge-pathnames "score-view.lisp" *source-directory*))
           (funcall (symbol-function 'open-score-view) root))
          (t (error "Use :score [status|work [ROLE]|session [end]|at|stop|jump SECTION|seek SECONDS|panel|mix|select SECTION|play [SECTION]|a|b|add-bars N|apply TOKEN|undo REVISION|stems DIRECTORY].")))))

(unless (sb-ext:posix-getenv "SCORE_CONSOLE_LOAD_ONLY")
  (handler-case
      (destructuring-bind (root &rest args) (rest sb-ext:*posix-argv*)
        (score-command (truename (dirpath root)) args))
    (error (condition)
      (format *error-output* "~&Score: ~A~%" condition)
      (sb-ext:exit :code 1))))
