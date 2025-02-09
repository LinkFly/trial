#|
 This file is a part of trial
 (c) 2017 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.trial)

(defclass placeholder-resource (resource)
  ((generator :initform (error "GENERATOR required."))
   (name :initform T)))

(defmethod print-object ((resource placeholder-resource) stream)
  (let ((asset (generator resource)))
    (print-unreadable-object (resource stream :type T)
      (format stream "~a/~a[~a]" (name (pool asset)) (name asset) (name resource)))))

(defmethod allocated-p ((resource placeholder-resource)) NIL)

(defmethod allocate ((resource placeholder-resource))
  (load (generator resource))
  (cond ((typep resource 'placeholder-resource)
         (error "Loading the asset~%  ~a~%did not generate the resource~%  ~a"
                (generator resource) resource))
        (T
         ;; We should have been change class'd by now, so re-call.
         (allocate resource))))

(defmethod unload ((resource placeholder-resource)))

(defmethod dependencies ((resource placeholder-resource))
  (list (generator resource)))

(defclass asset (resource-generator)
  ((pool :initform NIL :accessor pool)
   (name :initform NIL :accessor name)
   (input :initarg :input :accessor input)
   (loaded-p :initform NIL :accessor loaded-p)
   (generation-arguments :initform () :initarg :generation-arguments :accessor generation-arguments)))

(defgeneric load (asset))
(defgeneric reload (asset))
(defgeneric unload (asset))
(defgeneric list-resources (asset))
(defgeneric coerce-asset-input* (asset input))

(defun // (pool asset &optional (resource T))
  (resource (asset pool asset) resource))

(define-compiler-macro // (&whole whole pool asset &optional (resource T) &environment env)
  ;; We can do this because an asset's generated resources must be updated in place.
  (if (and (constantp pool env)
           (constantp asset env))
      (if (constantp resource env)
          `(load-time-value (resource (asset ,pool ,asset) ,resource))
          `(resource (asset ,pool ,asset) ,resource))
      whole))

(defmethod shared-initialize :after ((asset asset) slots &key pool name)
  (check-type name symbol)
  (when name
    (setf (name asset) name))
  (when pool
    (setf (pool asset) (etypecase pool
                         (symbol (find-pool pool T))
                         (pool pool))))
  (setf (asset pool name) asset))

(defmethod reinitialize-instance :after ((asset asset) &key)
  (when (loaded-p asset)
    (reload asset)))

(defmethod update-instance-for-different-class :around ((previous asset) (current asset) &key)
  (cond ((loaded-p previous)
         (unload previous)
         (call-next-method)
         (load current))
        (T
         (call-next-method))))

(defmethod print-object ((asset asset) stream)
  (print-unreadable-object (asset stream :type T)
    (format stream "~a/~a" (name (pool asset)) (name asset))))

(defmethod resource ((asset asset) id)
  (error "The asset~%  ~a~%does not hold a resource named~%  ~a"
         asset id))

(defmethod reload ((asset asset))
  (when (and (loaded-p asset) *context*)
    (with-context (*context*)
      (deallocate asset)
      (loop for resource in (enlist (apply #'generate-resources asset (input* asset) (generation-arguments asset)))
            do (dolist (dependency (dependencies resource))
                 (allocate dependency))
               (allocate resource)))))

(defmethod load ((asset asset))
  (apply #'generate-resources asset (input* asset) (generation-arguments asset)))

(defmethod load :around ((asset asset))
  (unless (loaded-p asset)
    (v:trace :trial.asset "Loading ~a/~a" (name (pool asset)) (name asset))
    (call-next-method)))

(defmethod generate-resources :after ((asset asset) input &key)
  (setf (loaded-p asset) T))

(defmethod unload :around ((asset asset))
  (when (loaded-p asset)
    (v:trace :trial.asset "Unloading ~a/~a" (name (pool asset)) (name asset))
    (call-next-method)))

(defmethod unload :after ((asset asset))
  (setf (loaded-p asset) NIL))

(defmethod deallocate :after ((asset asset))
  (setf (loaded-p asset) NIL))

(defmethod coerce-asset-input ((asset asset) (input (eql T)))
  (coerce-asset-input asset (input asset)))

(defmethod coerce-asset-input ((asset asset) thing)
  thing)

(defmethod coerce-asset-input ((asset asset) (path pathname))
  (pool-path (pool asset) path))

(defmethod coerce-asset-input ((asset asset) (list list))
  (loop for item in list collect (coerce-asset-input asset item)))

(defmethod input* ((asset asset))
  (coerce-asset-input asset (input asset)))

(defmethod register-generation-observer :after (observer (asset asset))
  (when (loaded-p asset)
    (observe-generation observer asset (list-resources asset))))

(defmacro define-asset ((pool name) type input &rest options)
  (check-type pool symbol)
  (check-type name symbol)
  (check-type type symbol)
  `(ensure-instance (asset ',pool ',name NIL) ',type
                    :input ,input
                    :name ',name
                    :pool ',pool
                    :generation-arguments (list ,@options)))

(trivial-indent:define-indentation define-asset (4 6 4 &body))

(defclass single-resource-asset (asset)
  ((resource)))

(defmethod initialize-instance :after ((asset single-resource-asset) &key)
  (setf (slot-value asset 'resource) (make-instance 'placeholder-resource :generator asset)))

(defmethod resource ((asset single-resource-asset) (id (eql T)))
  (slot-value asset 'resource))

(defmethod list-resources ((asset single-resource-asset))
  (list (resource asset T)))

(defmethod unload ((asset single-resource-asset))
  (unload (resource asset T)))

(defmethod deallocate ((asset single-resource-asset))
  (when (allocated-p (resource asset T))
    (deallocate (resource asset T)))
  (change-class (resource asset T) 'placeholder-resource :generator asset))

(defclass multi-resource-asset (asset)
  ((resources :initform (make-hash-table :test 'equal))))

(defmethod resource ((asset multi-resource-asset) id)
  (let ((table (slot-value asset 'resources)))
    (or (gethash id table)
        (setf (gethash id table)
              (make-instance 'placeholder-resource :generator asset)))))

(defmethod list-resources ((asset multi-resource-asset))
  (loop for resource being the hash-values of (slot-value asset 'resources)
        collect resource))

(defmethod unload ((asset multi-resource-asset))
  (loop for resource being the hash-values of (slot-value asset 'resources)
        do (unload resource)))

(defmethod deallocate ((asset multi-resource-asset))
  (loop for name being the hash-keys of (slot-value asset 'resources)
        for resource being the hash-values of (slot-value asset 'resources)
        do (when (allocated-p resource)
             (deallocate resource))
           (change-class resource 'placeholder-resource :name name :generator asset)))

(defclass file-input-asset (asset)
  ())

(defmethod shared-initialize :after ((asset file-input-asset) slots &key &allow-other-keys)
  (let ((file (input* asset)))
    (unless (probe-file file)
      (alexandria:simple-style-warning "Input file~% ~s~%for asset~%  ~s~%does not exist." file asset))))

(defmethod compile-resources ((asset asset) (source (eql T)) &rest args &key &allow-other-keys)
  (when (typep asset 'compiled-generator)
    (apply #'compile-resources asset (input* asset) args)))

(defmethod compile-resources ((all (eql T)) _ &rest args &key &allow-other-keys)
  (dolist (pool (list-pools))
    (dolist (asset (list-assets pool))
      (apply #'compile-resources asset T args))))
