(require :sb-bsd-sockets)
(in-package #:score-prototype)

(defun escape-html (value)
  (with-output-to-string (out)
    (loop for char across value do
      (princ (case char (#\& "&amp;") (#\< "&lt;") (#\> "&gt;")
               (#\" "&quot;") (otherwise char)) out))))

(load (merge-pathnames "score-staff.lisp" *source-directory*))

(defun score-page (root &optional message)
  (let* ((project (project-state root))
         (selected (selection root project))
         (rev (getf project :revision))
         (sections (getf project :sections))
         (unit (getf project :beats-per-bar)))
    (with-output-to-string (out)
      (write-string "<!doctype html><html lang='zh-Hant'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>AMOEBA / SCORE</title>
<style>
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0 auto;max-width:1100px;padding:1.6rem;background:#0b1118;color:#dce6f4;font:16px/1.5 monospace}header{display:flex;align-items:center;gap:1rem;flex-wrap:wrap;border-bottom:1px solid #324253;padding-bottom:.8rem}h1{font-size:1.65rem;margin:0 auto 0 0}small,p{color:#9db0c4}.map{display:flex;overflow-x:auto;gap:8px}.map form{flex:var(--bars) 0 7rem}button,a{font:inherit;color:#dce6f4;background:#111e2a;border:1px solid #40586e;padding:.65rem 1rem;min-height:44px;border-radius:2px;cursor:pointer}.map button{width:100%;min-height:82px;text-align:left;border-top:3px solid #40586e}.map button[aria-pressed=true]{color:#a5f3fc;border-color:#67e8f9;background:#122c37}.map strong,.map small{display:block}button:focus-visible,a:focus-visible{outline:2px solid #fbbf24;outline-offset:2px}table{width:100%;border-collapse:collapse;margin-top:.75rem;text-align:left}th,td{padding:.45rem;border-bottom:1px solid #273849}.pinned{color:#fbbf24}.staves{overflow:auto;border:1px solid #40586e;color:#a5f3fc}.staves text{fill:currentColor;stroke:none}.transport{display:flex;gap:8px;flex-wrap:wrap;margin:1rem 0}
</style><header>" out)
      (format out "<h1>~A</h1><small>REV ~D</small><a href='./'>重新整理</a><form method='post' action='close'><button>回到 Lisp</button></form></header>"
              (escape-html (getf project :title)) rev)
      (when message (format out "<p role='status'>~A</p>" (escape-html message)))
      (write-string "<div class='transport'>" out)
      (loop for (action label) in '(("play" "播放選定段落") ("a" "A 原版") ("b" "B 預覽") ("stop" "停止"))
            do (format out "<form method='post' action='~A'><button>~A</button></form>" action label))
      (write-string "</div>" out)
      (format out "<p>目前段落 <strong>~A</strong> · 點選段落即播放，可在 Lisp 執行 <code>:score add-bars 2</code> 預覽。</p><div class='map' aria-label='段落'>"
              (if selected (escape-html (first selected)) "未選擇"))
      (loop with bar = 1 for entry in sections for index from 0
            for (id count) = entry
            do (format out "<form method='post' action='select/~D/~D' style='--bars:~D'><button aria-pressed='~A'><strong>~A</strong><small>小節 ~D–~D</small></button></form>"
                       rev index count (if (eq entry selected) "true" "false") (escape-html id)
                       bar (+ bar count -1))
               (incf bar count))
      (write-string "</div>" out)
      (score-staves out root project)
      (write-string "<table><thead><tr><th scope='col'>分譜</th><th scope='col'>譜上事件與定位</th></tr></thead><tbody>" out)
      (dolist (part (getf project :parts))
        (format out "<tr><th scope='row'>~A</th><td>" (escape-html part))
        (dolist (item (getf project :items))
          (when (equal (getf item :part) part)
            (let ((pinned (eq (getf item :unit) :frame)))
              (format out "<div~A>~A · ~A · ~A ~:D</div>"
                      (if pinned " class='pinned'" "") (escape-html (getf item :id))
                      (ecase (getf item :kind) (:notation "譜面") (:clip "剪輯") (:automation "自動化"))
                      (if pinned "鎖定 frame" "小節")
                      (if pinned (getf item :start) (1+ (floor (getf item :start) unit)))))))
        (write-string "</td></tr>" out))
      (write-string "</tbody></table></html>" out))))

(defun score-http-line (stream)
  (with-output-to-string (out)
    (loop for index below 2048 for char = (read-char stream nil)
          until (or (null char) (char= char #\Newline))
          unless (char= char #\Return) do (write-char char out)
          finally (when (= index 2048) (error "Oversized request.")))))

(defun score-http-response (out status body &optional location)
  (let ((crlf (format nil "~C~C" #\Return #\Newline)))
    (format out "HTTP/1.1 ~A~AContent-Type: text/html; charset=utf-8~AContent-Length: ~D~AConnection: close~ACache-Control: no-store~AReferrer-Policy: same-origin~AX-Content-Type-Options: nosniff~AContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'~A"
            status crlf crlf (length (sb-ext:string-to-octets body :external-format :utf-8))
            crlf crlf crlf crlf crlf crlf)
    (when location (format out "Location: ~A~A" location crlf))
    (write-string crlf out)
    (write-string body out)
    (finish-output out)))

(defun handle-score-request (client root host base transport)
  (sb-ext:with-timeout 8
    (with-open-stream (stream (sb-bsd-sockets:socket-make-stream
                               client :input t :output t :element-type 'character
                               :external-format :utf-8 :buffering :full))
      (let* ((line (score-http-line stream))
             (space (position #\Space line))
             (end (position #\Space line :from-end t))
             (method (and space (subseq line 0 space)))
             (path (and space (> end space) (subseq line (1+ space) end)))
             (valid-host nil) (valid-origin nil)
             (origin (format nil "http://~A" host)))
        (loop repeat 48 for header = (score-http-line stream) until (equal header "")
              do (let ((colon (position #\: header)))
                   (when colon
                     (let ((name (subseq header 0 colon))
                           (value (string-trim '(#\Space #\Tab) (subseq header (1+ colon)))))
                       (cond ((string-equal name "Host") (setf valid-host (equal value host)))
                             ((string-equal name "Origin") (setf valid-origin (equal value origin))))))))
        (cond
          ((and valid-host (equal method "GET") (equal path base))
           (score-http-response stream "200 OK" (score-page root)))
          ((and valid-host valid-origin (equal method "POST") path
                (equal path (concatenate 'string base "close")))
           (score-http-response stream "200 OK" "<p>Returning to Lisp.</p>")
           :close)
          ((and valid-host valid-origin (equal method "POST") path
                (let ((prefix (concatenate 'string base "select/")))
                  (eql 0 (search prefix path))))
           (handler-case
               (let* ((offset (+ (length base) 7))
                      (slash (position #\/ path :start offset))
                      (rev (and slash (parse-integer path :start offset :end slash)))
                      (index (and slash (parse-integer path :start (1+ slash))))
                      (snapshot (project-state root))
                      (entry (and index (<= 0 index) (nth index (getf snapshot :sections)))))
                 (unless (and entry (eql rev (getf snapshot :revision))) (error "Stale section."))
                 (select-section root (first entry) rev)
                 (funcall transport "play")
                 (score-http-response stream "303 See Other" "" base))
             (error (condition)
               (score-http-response stream "409 Conflict" (score-page root (princ-to-string condition))))))
          ((and valid-host valid-origin (equal method "POST") path
                (eql 0 (search base path))
                (member (subseq path (length base)) '("play" "a" "b" "stop") :test #'equal))
           (handler-case
               (progn (funcall transport (subseq path (length base)))
                      (score-http-response stream "303 See Other" "" base))
             (error (condition)
               (score-http-response stream "409 Conflict" (score-page root (princ-to-string condition))))))
          (t (score-http-response stream "404 Not Found" "Not found.")))))))

(defun call-with-score-server (function)
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-bind socket #(127 0 0 1) 0)
           (sb-bsd-sockets:socket-listen socket 8)
           (let* ((host (format nil "127.0.0.1:~D" (nth-value 1 (sb-bsd-sockets:socket-name socket))))
                  (base (format nil "/~A/" (score-nonce))))
             (funcall function socket host base)))
      (sb-bsd-sockets:socket-close socket))))

(defun score-server-step (socket root host base transport)
  (when (sb-sys:wait-until-fd-usable (sb-bsd-sockets:socket-file-descriptor socket) :input .15)
    (let ((client (sb-bsd-sockets:socket-accept socket)))
      (unwind-protect
           (handler-case (handle-score-request client root host base transport)
             (error () nil))
        (ignore-errors (sb-bsd-sockets:socket-close client))))))

(defun open-score-view (root)
  (call-with-score-server
   (lambda (socket host base)
     (let ((viewer (spawn-amoeba-viewer (format nil "http://~A~A" host base))))
         (let ((audio nil))
           (unwind-protect
                (loop while (sb-ext:process-alive-p viewer)
                      do (when (and audio (not (sb-ext:process-alive-p (car audio))))
                           (finish-audition audio)
                           (setf audio nil))
                      until (eq :close (score-server-step
                                        socket root host base
                                        (lambda (mode)
                                          (finish-audition audio t)
                                          (setf audio nil)
                                          (unless (equal mode "stop")
                                            (setf audio (start-score-playback root mode)))))))
             (unwind-protect (finish-audition audio t)
               (when (sb-ext:process-alive-p viewer) (sb-ext:process-kill viewer 15))
               (sb-ext:process-wait viewer))))
         (unless (eql 0 (sb-ext:process-exit-code viewer))
           (error "Score viewer exited with status ~A." (sb-ext:process-exit-code viewer)))))))
