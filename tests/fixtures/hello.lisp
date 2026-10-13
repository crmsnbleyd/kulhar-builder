(defpackage #:kulhar-smoke (:use #:cl) (:export #:greeting #:main))
(in-package #:kulhar-smoke)

(defun greeting () "hello from a fasl")

(defun main ()
  (write-line "hello from a saved core")
  (finish-output))
