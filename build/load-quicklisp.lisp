;;;; load-quicklisp.lisp -- load this image's pinned Quicklisp client.
;;;;
;;;; The client is installed read-only in /usr/local/lib/kulhar-builder/quicklisp/.
;;;; Quicklisp keeps its dists, local projects and temporary files next to its
;;;; setup.lisp, so on first use (or when the image's client version changes)
;;;; the client files are copied into a writable home:
;;;;
;;;;   $KULHAR_QUICKLISP_HOME, default /var/cache/kulhar/quicklisp/
;;;;
;;;; No dist is installed. Install one with QL-DIST:INSTALL-DIST.
;;;;
;;;; Usage: sbcl --load /usr/local/share/kulhar-builder/load-quicklisp.lisp

(require :asdf)

(defpackage #:kulhar-builder/load-quicklisp
  (:use #:cl))

(in-package #:kulhar-builder/load-quicklisp)

(defparameter *client* #p"/usr/local/lib/kulhar-builder/quicklisp/")

(defparameter *home*
  (uiop:ensure-directory-pathname
   (or (uiop:getenvp "KULHAR_QUICKLISP_HOME") "/var/cache/kulhar/quicklisp/")))

(defun client-version (root)
  (let ((file (merge-pathnames "quicklisp/version.txt" root)))
    (and (probe-file file) (uiop:read-file-string file))))

(defun copy-client ()
  ;; Copy through a temporary name and rename, so concurrent builds sharing
  ;; one cache never see a half-written file.
  (let ((*random-state* (make-random-state t)))
    (dolist (dir '("" "quicklisp/"))
      (let ((to (merge-pathnames dir *home*)))
        (ensure-directories-exist to)
        (dolist (file (uiop:directory-files (merge-pathnames dir *client*)))
          (let* ((target (merge-pathnames (file-namestring file) to))
                 (tmp (uiop:parse-native-namestring
                       (format nil "~A.~36R.tmp" (uiop:native-namestring target)
                               (random (expt 36 8))))))
            (uiop:copy-file file tmp)
            (uiop:rename-file-overwriting-target tmp target)))))))

(unless (and (probe-file (merge-pathnames "setup.lisp" *home*))
             (equal (client-version *home*) (client-version *client*)))
  (copy-client))

;; Quicklisp installs the latest dist on first load unless dists/ exists.
(ensure-directories-exist (merge-pathnames "dists/" *home*))

(load (merge-pathnames "setup.lisp" *home*))
