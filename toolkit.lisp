#|
 This file is a part of Qtools
 (c) 2015 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.qtools.libs.generator)

(defun externalize (thing)
  (typecase thing
    (list thing)
    (string thing)
    (pathname (uiop:native-namestring thing))
    (T (princ-to-string thing))))

(defun status (n string &rest format-args)
  (format T "~&~a ~a~%"
          (case n (0 ">") (1 " ->") (2 " ==>") (T "  >>>"))
          (apply #'format NIL string format-args)))

(defun run (string &rest format-args)
  (let ((program (apply #'format NIL string (mapcar #'externalize format-args))))
    (uiop:run-program program :output T :error-output T)))

(defun run-here (string &rest format-args)
  (status 1 "Running ~a" program)
  (apply #'run string format-args))

(defun clone (origin target)
  (test-prerequisite "GIT" "git")
  (status 2 "Cloning ~a" origin)
  (run-here "git clone ~s ~s" origin target))

(defun ensure-system (system &optional (package system))
  (unless (find-package package)
    (let (#+sbcl (sb-ext:*muffled-warnings* 'style-warning))
      #-quicklisp (asdf:load-system system)
      #+quicklisp (ql:quickload system))))

(defun checksum-string (vector)
  (with-output-to-string (*standard-output*)
    (map NIL (lambda (c) (write c :base 36)) vector)))

(defun checksum-file (target)
  (ensure-system :sha3)
  (funcall (find-symbol (string :sha3-digest-file) :sha3) target))

(defun download-file (url target)
  (status 1 "Downloading ~a" url)
  (ensure-system :drakma)
  (with-open-file (output target :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create
                                 :element-type '(unsigned-byte 8))
    (multiple-value-bind (input status) (funcall (find-symbol (string :http-request) :drakma) url :want-stream T)
      (unwind-protect
           (progn
             (unless (= status 200)
               (error "Bad status code: ~s" status))
             (loop for byte = (read-byte input NIL NIL)
                   while byte
                   do (write-byte byte output)))
        (close input)))))

(defun safely-download-file (url target checksum)
  (loop do (download-file url target)
        until (cond (checksum
                     (with-simple-restart (retry "Retry downloading.")
                       (let ((file-checksum (checksum-file target)))
                         (unless (equalp checksum file-checksum)
                           (cerror "I am sure that this is fine."
                                   "SHA3 file mismatch for ~s!~
                           ~&Expected ~a~
                           ~&got      ~a"
                                   (uiop:native-namestring target) (checksum-string checksum) (checksum-string file-checksum)))
                         (status 1 "Checksum test passed")
                         T)))
                    (T (status 1 "No checksum available, skipping test.")
                       T))))

(defun extract-tar-archive (from to &key (strip-folder))
  (test-prerequisite "tar" "tar")
  (status 2 "Extracting ~a" (uiop:native-namestring from))
  (run-here "tar ~@[--strip-components=1 ~*~] -xpf ~s -C ~s" strip-folder from to))

(defun relative-dir (relative &rest subdirs)
  (loop for sub in subdirs
        for dir = (merge-pathnames (uiop:ensure-directory-pathname sub)
                                   (uiop:ensure-directory-pathname relative))
        then (merge-pathnames (uiop:ensure-directory-pathname sub) dir)
        finally (return dir)))

(defmacro with-chdir ((to) &body body)
  (let ((current (gensym "CURRENT")))
    `(let ((,current (uiop:getcwd)))
       (unwind-protect
            (progn
              (uiop:chdir
               (uiop:pathname-directory-pathname
                (ensure-directories-exist ,to)))
              ,@body)
         (uiop:chdir ,current)))))

(defmacro with-temp-file ((name pathname) &body body)
  `(let ((,name ,pathname))
     (unwind-protect
          (progn ,@body)
       (uiop:delete-file-if-exists ,name))))

(defun application-available-p (&rest alternatives)
  (zerop (nth-value 2 (uiop:run-program (format NIL "~{command -v ~s~^ || ~}" alternatives) :ignore-error-status T))))

(defun test-prerequisite (name &rest alternatives)
  (with-simple-restart (continue "I know what I'm doing, skip this test.")
    (loop until (if (apply #'application-available-p alternatives)
                    T
                    (with-simple-restart (retry "I installed it now, test again.")
                      (error "~a is required, but could not be found. Please ensure it is installed properly." name))))))

(defvar *max-cpus* most-positive-fixnum)
(defun cpu-count ()
  (min (or (parse-integer (uiop:run-program "nproc" :ignore-error-status T :output :string) :junk-allowed T)
           2)
       *max-cpus*))

(defun shared-library-file (&rest args &key host device directory name version defaults)
  (declare (ignore host device directory name version defaults))
  (apply #'make-pathname :type #+windows "dll" #+darwin "dylib" #-(or windows darwin) "so" args))

(defun filename (pathname)
  (format NIL "~a.~a" (pathname-name pathname) (pathname-type pathname)))

(defun dylib-dependencies (pathname)
  (with-chdir (pathname)
    (let ((lines (cl-ppcre:split "\\s*\\n\\s*" (uiop:run-program (format NIL "otool -L ~s" (filename pathname)) :output :string))))
      (mapcar (lambda (line)
                (cl-ppcre:register-groups-bind (name) ("^(.*) \\(compatibility version" line)
                  name))
              (cdr lines)))))

(defun dylib-set-install-name (pathname name)
  (with-chdir (pathname)
    (run "install_name_tool -id ~s ~s" name (filename pathname))))

(defun dylib-set-dependency-name (pathname dependency name)
  (with-chdir (pathname)
    (run "install_name_tool -change ~s ~s ~s" dependency name (filename pathname))))

;; This is stupid, but I can't be bothered to do better.
(defun find-similar (pathname files)
  (let ((stripped (cl-ppcre:register-groups-bind (NIL name) ("(lib)?(.*?)\\." (filename pathname)) name)))
    (loop for file in files
          when (search stripped (filename file))
          return file)))

(defun fix-dylib-paths (pathname)
  ;; Primitively set the install name to the filename
  (dylib-set-install-name pathname (filename pathname))
  ;; Primitively change relative paths to use @loader-path and matching name in dir.
  (let ((files (remove "dylib" (uiop:directory-files pathname) :key #'pathname-type :test-not #'string=)))
    (dolist (dep (dylib-dependencies pathname))
      (let ((dep (pathname dep)))
        (when (uiop:relative-pathname-p dep)
          (dylib-set-dependency-name
           pathname dep
           (let ((corresponding (find-similar dep files)))
             (if corresponding
                 (format NIL "@loader_path/~a" (filename corresponding))
                 (filename dep))))))))
  pathname)
