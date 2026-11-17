(require :sb-posix)
(defpackage #:score-prototype
  (:use #:cl)
  (:export #:preview-insertion #:apply-insertion #:rollback #:project-state #:devices #:route-plan))
(in-package #:score-prototype)

(sb-alien:define-alien-routine ("flock" file-lock) sb-alien:int
  (fd sb-alien:int) (operation sb-alien:int))

(defparameter *source-directory* (make-pathname :name nil :type nil :defaults *load-truename*))

(defun dirpath (path)
  (pathname (concatenate 'string (string-right-trim "/" (namestring (pathname path))) "/")))

(defun project-file (root name)
  (merge-pathnames name (dirpath root)))

(defun revision-file (root revision)
  (project-file root (format nil "revisions/~D.sexp" revision)))

(defun read-data (path)
  (with-open-file (stream path :external-format :utf-8)
    (with-standard-io-syntax
      (let ((*read-eval* nil) (eof (gensym)))
        (prog1 (read stream)
          (unless (eq (read stream nil eof) eof)
            (error "Unexpected trailing data in ~A." path)))))))

(defun write-data (path value)
  (multiple-value-bind (fd temp)
      (sb-posix:mkstemp (concatenate 'string (namestring path) ".XXXXXX"))
    (sb-posix:close fd)
    (let ((temp-path (pathname temp)))
    (unwind-protect
         (progn
           (with-open-file (stream temp-path :direction :output :if-exists :supersede
                                            :external-format :utf-8)
             (with-standard-io-syntax
               (let ((*print-pretty* t) (*print-circle* nil))
                 (write value :stream stream)
                 (terpri stream)
                 (finish-output stream)
                 (sb-posix:fsync (sb-sys:fd-stream-fd stream)))))
           (sb-posix:rename temp (namestring path)))
      (when (probe-file temp-path) (delete-file temp-path))))))

(defun call-with-project-lock (root function)
  (ensure-directories-exist (revision-file root 0))
  (with-open-file (lock (project-file root "write.lock") :direction :output
                         :if-exists :append :if-does-not-exist :create)
    (unless (zerop (file-lock (sb-sys:fd-stream-fd lock) 2))
      (error "Could not lock project."))
    (funcall function)))

(defun project-state (root)
  (let ((revision (read-data (project-file root "HEAD.sexp"))))
    (check-type revision (integer 0))
    (read-data (revision-file root revision))))

(defun beats-to-frame (project beats)
  (round (* beats (/ (* (getf project :sample-rate) 60) (getf project :bpm)))))

(defun next-revision (root base)
  (loop for id from (1+ base)
        unless (probe-file (revision-file root id)) return id))

(defun commit-project (root project base)
  (let* ((id (next-revision root base))
         (snapshot (copy-tree project)))
    (setf (getf snapshot :revision) id (getf snapshot :parent) base)
    (write-data (revision-file root id) snapshot)
    (write-data (project-file root "HEAD.sexp") id)
    id))

(defun section-boundary (project section)
  (let ((bars 0) (beats-per-bar (getf project :beats-per-bar)))
    (dolist (entry (getf project :sections))
      (incf bars (second entry))
      (when (string-equal (first entry) section)
        (return-from section-boundary (* bars beats-per-bar))))
    (error "Unknown section: ~A" section)))

(defun impact-for (item cut beats cut-frame end-frame)
  (destructuring-bind (&key id kind part unit start duration &allow-other-keys) item
    (let ((action
            (ecase unit
              (:frame :pinned)
              (:beat (cond ((>= start cut) :shift)
                           ((> (+ start duration) cut) :review)
                           (t :unchanged))))))
      (list :id id :kind kind :part part :unit unit :action action :from start
            :to (if (eq action :shift) (+ start beats) start)
            :in-inserted-time (and (eq action :pinned) (< start end-frame)
                                   (if (zerop duration) (<= cut-frame start)
                                       (> (+ start duration) cut-frame)))))))

(defun confirmation-token (revision section bars)
  (format nil "~D:~A:+~D" revision (string-upcase section) bars))

(defun preview-state (project section bars)
  (check-type bars (integer 1 1000))
  (let* ((beats (* bars (getf project :beats-per-bar)))
         (cut (section-boundary project section))
         (cut-frame (beats-to-frame project cut))
         (end-frame (beats-to-frame project (+ cut beats)))
         (effects (mapcar (lambda (item) (impact-for item cut beats cut-frame end-frame))
                          (getf project :items))))
    (list :revision (getf project :revision) :section (string-upcase section)
          :bars bars :beats beats
          :confirmation (confirmation-token (getf project :revision) section bars)
          :boundary-beat cut :boundary-frame cut-frame
          :parts (copy-list (getf project :parts)) :effects effects)))

(defun preview-insertion (root section bars)
  (preview-state (project-state root) section bars))

(defun assert-revision (project expected)
  (unless (eql (getf project :revision) expected)
    (error "Expected revision ~D, current revision is ~D. Preview again."
           expected (getf project :revision))))

(defun project-insertion (base plan)
  (when (find :review (getf plan :effects) :key (lambda (row) (getf row :action)))
    (error "An item spans the edit boundary. Resolve it before applying."))
  (let ((project (copy-tree base)))
    (incf (second (assoc (getf plan :section) (getf project :sections) :test #'string-equal))
          (getf plan :bars))
    (loop for item in (getf project :items)
          for row in (getf plan :effects)
          do (setf (getf item :start) (getf row :to)))
    project))

(defun commit-insertion (root base plan)
  (commit-project root (project-insertion base plan) (getf base :revision)))

(defun apply-insertion (root section bars confirmation)
  (call-with-project-lock
   root
   (lambda ()
     (let* ((base (project-state root))
            (plan (preview-state base section bars)))
       (unless (equal confirmation (getf plan :confirmation))
         (error "Confirmation does not match this edit and revision. Preview again."))
       (commit-insertion root base plan)))))

(defun rollback (root expected)
  (call-with-project-lock
   root
   (lambda ()
     (let* ((current (project-state root)) (parent (getf current :parent)))
       (assert-revision current expected)
       (unless parent (error "This revision has no previous version."))
       (commit-project root (read-data (revision-file root parent)) expected)))))

(defun print-plan (plan)
  (format t "Revision ~D | section ~A +~D bars | insertion at beat ~D / frame ~D~%"
          (getf plan :revision) (getf plan :section) (getf plan :bars)
          (getf plan :boundary-beat) (getf plan :boundary-frame))
  (format t "Confirmation: ~A~%" (getf plan :confirmation))
  (format t "Parts with inserted bars: ~{~A~^, ~}~%" (getf plan :parts))
  (dolist (row (getf plan :effects))
    (format t "  ~A  ~A (~A/~A): ~D -> ~D ~A~:[~;  [overlaps inserted bars]~]~%"
            (getf row :action) (getf row :id) (getf row :kind) (getf row :part)
            (getf row :from) (getf row :to) (getf row :unit) (getf row :in-inserted-time))))

(defun print-parts (project)
  (dolist (part (getf project :parts))
    (format t "~A~%" part)
    (loop with bar = 1 for (section count) in (getf project :sections)
          do (format t "  ~A: bars ~D–~D~%" section bar (+ bar count -1))
             (incf bar count))
    (dolist (item (getf project :items))
      (when (and (eq :notation (getf item :kind)) (string= part (getf item :part)))
        (format t "  ~A: bar ~D (~D beats)~%" (getf item :id)
                (1+ (floor (getf item :start) (getf project :beats-per-bar)))
                (getf item :duration))))))
