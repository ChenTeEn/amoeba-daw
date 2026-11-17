(in-package #:score-prototype)

(sb-alien:load-shared-object (or (sb-ext:posix-getenv "AMOEBA_ALSA_LIBRARY") "libasound.so.2"))

(defmacro stream-alsa (c name result &rest arguments)
  `(sb-alien:define-alien-routine (,c ,name) ,result ,@arguments))

(stream-alsa "snd_pcm_open" stream-open sb-alien:int
 (out (* sb-alien:system-area-pointer)) (device sb-alien:c-string) (direction sb-alien:int) (flags sb-alien:int))
(stream-alsa "snd_pcm_nonblock" stream-nonblock sb-alien:int
 (handle sb-alien:system-area-pointer) (nonblock sb-alien:int))
(stream-alsa "snd_pcm_set_params" stream-params sb-alien:int
 (handle sb-alien:system-area-pointer) (format sb-alien:int) (access sb-alien:int)
 (channels sb-alien:unsigned) (rate sb-alien:unsigned) (resample sb-alien:int) (latency sb-alien:unsigned))
(stream-alsa "snd_pcm_writei" stream-write sb-alien:long
 (handle sb-alien:system-area-pointer) (pointer sb-alien:system-area-pointer) (frames sb-alien:unsigned-long))
(stream-alsa "snd_pcm_delay" stream-delay sb-alien:int
 (handle sb-alien:system-area-pointer) (delay (* sb-alien:long)))
(stream-alsa "snd_pcm_recover" stream-recover sb-alien:int
 (handle sb-alien:system-area-pointer) (code sb-alien:int) (silent sb-alien:int))
(stream-alsa "snd_pcm_drop" stream-drop sb-alien:int (handle sb-alien:system-area-pointer))
(stream-alsa "snd_pcm_prepare" stream-prepare sb-alien:int (handle sb-alien:system-area-pointer))
(stream-alsa "snd_pcm_drain" stream-drain sb-alien:int (handle sb-alien:system-area-pointer))
(stream-alsa "snd_pcm_close" stream-close sb-alien:int (handle sb-alien:system-area-pointer))
(stream-alsa "snd_pcm_format_value" stream-format sb-alien:int (name sb-alien:c-string))
(stream-alsa "snd_strerror" stream-error-text sb-alien:c-string (code sb-alien:int))

(defconstant +stream-block+ 256)

(defstruct mix-stream bank thread stop seek cursor ready error (xruns 0) (blocks 0) levels)

(defun stream-check (code)
  (when (minusp code) (error "ALSA: ~A" (stream-error-text code)))
  code)

(defun stream-mix-block (bank from frames output levels)
  (declare (type sample-vector output levels) (type fixnum from frames)
           (optimize (speed 3) (safety 1)))
  (fill output 0)
  (loop for (samples . gain) across bank
        for track of-type fixnum from 0
        do (let ((left 0) (right 0))
             (declare (type fixnum left right))
             (loop for i of-type fixnum from 0 below (* 2 frames) by 2
                   for j of-type fixnum from (* 2 from) by 2
                   for l of-type fixnum = (round (* (the double-float gain)
                                                    (aref (the sample-vector samples) j)))
                   for r of-type fixnum = (round (* (the double-float gain)
                                                    (aref (the sample-vector samples) (1+ j))))
                   do (incf (aref output i) l)
                      (incf (aref output (1+ i)) r)
                      (setf left (max left (abs l)) right (max right (abs r))))
             (when (plusp (length levels))
               (setf (aref levels (* track 2)) (max left (floor (* 7 (aref levels (* track 2))) 8))
                     (aref levels (1+ (* track 2))) (max right (floor (* 7 (aref levels (1+ (* track 2)))) 8)))))))

(defun stream-pack-block (output old frames blend)
  (declare (type sample-vector output old) (type fixnum frames)
           (optimize (speed 3) (safety 1)))
  (loop for i of-type fixnum below (* frames 2)
        for new of-type fixnum = (aref output i)
        for value of-type fixnum =
          (if blend (round (+ (* (- frames (ash i -1) 1) (aref old i))
                              (* (1+ (ash i -1)) new)) frames)
              new)
        do (setf (aref output i) (ash (min 8388607 (max -8388608 value)) 8))))

(defun run-mix-stream (state device rate frames)
  (handler-case
      (sb-alien:with-alien ((pcm sb-alien:system-area-pointer) (pending sb-alien:long))
        (stream-check (stream-open (sb-alien:addr pcm) device 0 1))
        (unwind-protect
             (let ((output (make-array (* 2 +stream-block+) :element-type '(signed-byte 32)))
                   (old (make-array (* 2 +stream-block+) :element-type '(signed-byte 32)))
                   (no-meters (make-array 0 :element-type '(signed-byte 32)))
                   (last (mix-stream-bank state))
                   (next (mix-stream-cursor state))
                   (paced (equal device "null")))
               (stream-check (stream-nonblock pcm 0))
               (stream-check (stream-params pcm (stream-format "S32_LE") 3 2 rate 0 72000))
               (setf (mix-stream-ready state) t)
               (sb-sys:with-pinned-objects (output)
                 (loop until (mix-stream-stop state)
                       do (let ((seek (loop for old = (mix-stream-seek state)
                                            when (eq old (sb-ext:compare-and-swap (mix-stream-seek state) old nil))
                                              return old)))
                            (when seek
                              (stream-check (stream-drop pcm))
                              (stream-check (stream-prepare pcm))
                              (setf next seek (mix-stream-cursor state) seek)))
                          (when (>= next frames)
                            (stream-check (stream-drain pcm))
                            (setf (mix-stream-cursor state) frames)
                            (return))
                          (let* ((bank (mix-stream-bank state))
                                 (count (min +stream-block+ (- frames next)))
                                 (blend (not (eq bank last))))
                            (stream-mix-block bank next count output (mix-stream-levels state))
                            (when blend (stream-mix-block last next count old no-meters))
                            (stream-pack-block output old count blend)
                            (setf last bank)
                            (loop with done = 0 while (< done count) until (mix-stream-stop state)
                                  for written = (stream-write pcm
                                                (sb-sys:sap+ (sb-sys:vector-sap output) (* 8 done)) (- count done))
                                  do (if (plusp written)
                                         (incf done written)
                                         (progn (incf (mix-stream-xruns state))
                                                (stream-check (stream-recover pcm written 1))))
                                  finally (incf next done))
                            (when paced (sleep (/ count (float rate))))
                            (incf (mix-stream-blocks state))
                            (setf (mix-stream-cursor state)
                                  (max (mix-stream-cursor state) (if (zerop (stream-delay pcm (sb-alien:addr pending)))
                                             (- next (max 0 pending)) next)))))))
          (stream-close pcm)))
    (error (condition) (setf (mix-stream-error state) (princ-to-string condition)))))
