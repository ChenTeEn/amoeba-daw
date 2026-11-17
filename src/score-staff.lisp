(in-package #:score-prototype)

(defun staff-step (pitch)
  (multiple-value-bind (octave chroma) (floor pitch 12)
    (+ (* octave 7) (aref #(0 0 1 1 2 3 3 4 4 5 5 6) chroma))))

(defun staff-note (out x origin pitch duration)
  (let* ((step (- (staff-step pitch) (staff-step 64)))
         (y (- (+ origin 62) (* step 4)))
         (up (< step 4)))
    (loop for ledger from 10 to step by 2
          do (let ((ly (- (+ origin 62) (* ledger 4))))
               (format out "<path d='M~D ~Dh16'/>" (- x 8) ly)))
    (loop for ledger from -2 downto step by 2
          do (let ((ly (- (+ origin 62) (* ledger 4))))
               (format out "<path d='M~D ~Dh16'/>" (- x 8) ly)))
    (when (member (mod pitch 12) '(1 3 6 8 10))
      (format out "<text x='~D' y='~D'>♯</text>" (- x 16) (+ y 4)))
    (format out "<ellipse cx='~D' cy='~D' rx='5' ry='3.4' fill='~A'/>"
            x y (if (< duration 2) "currentColor" "#0b1118"))
    (when (< duration 4)
      (let ((stem (+ x (if up 4 -4))))
        (format out "<path d='M~D ~Dv~D'/>" stem y (if up -24 24))))))

(defun score-staff-system (out project data parts id meter left right)
  (let* ((stride 24) (width (+ 110 (* (- right left) stride))))
    (format out "<h3>~A · 小節 ~D–~D</h3><div class='staves' tabindex='0'><svg width='~D' height='~D' role='img' aria-label='五線譜'><g fill='none' stroke='currentColor'>"
            (escape-html id) (1+ (floor left meter)) (floor right meter)
            width (* 100 (length parts)))
    (loop for part in parts for origin from 0 by 100
          do (format out "<text x='6' y='~D'>~A</text><text x='47' y='~D' style='font-size:33px'>𝄞</text>"
                     (+ origin 18) (escape-html part) (+ origin 62))
             (loop for y from (+ origin 30) to (+ origin 62) by 8
                   do (format out "<path d='M44 ~DH~D'/>" y (- width 5)))
             (loop for beat from left to right by meter
                   for x = (+ 97 (* (- beat left) stride))
                   do (format out "<path d='M~D ~Dv32'/>" x (+ origin 30))
                      (when (< beat right)
                        (format out "<text x='~D' y='~D'>~D</text>"
                                (+ x 5) (+ origin 22) (1+ (floor beat meter)))))
             (dolist (event (getf project :items))
               (when (and (eq (getf event :kind) :notation) (equal part (getf event :part)))
                 (dolist (note (cdr (assoc (getf event :id) (getf data :notes) :test #'equal)))
                   (destructuring-bind (offset duration pitch) note
                     (let ((beat (+ (getf event :start) offset)))
                       (when (<= left beat (1- right))
                         (staff-note out (+ 109 (* stride (- beat left))) origin pitch duration))))))))
    (write-string "</g></svg></div>" out)))

(defun score-staves (out root project)
  (let* ((data (audition-data root))
         (meter (getf project :beats-per-bar))
         (parts (remove-if-not
                 (lambda (part)
                   (some (lambda (event)
                           (and (eq (getf event :kind) :notation)
                                (equal (getf event :part) part)))
                         (getf project :items)))
                 (getf project :parts))))
    (when (and data parts)
      (write-string "<h2>五線譜</h2>" out)
      (loop with start = 0 for (id bars) in (getf project :sections)
            for end = (+ start (* bars meter))
            do (loop for left from start below end by (* 10 meter)
                     for right = (min end (+ left (* 10 meter)))
                     do (score-staff-system out project data parts id meter left right))
               (setf start end)))))
