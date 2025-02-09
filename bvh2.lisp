(defpackage #:org.shirakumo.fraf.trial.bvh2
  (:use #:cl #:3d-vectors)
  (:import-from #:org.shirakumo.fraf.trial #:location #:bsize)
  (:export
   #:bvh
   #:make-bvh
   #:bvh-insert
   #:bvh-remove
   #:bvh-update
   #:bvh-check
   #:bvh-print
   #:bvh-lines
   #:call-with-contained
   #:call-with-overlapping
   #:do-fitting))

(in-package #:org.shirakumo.fraf.trial.bvh2)

;; CF https://www.researchgate.net/publication/254007711_Fast_Effective_BVH_Updates_for_Animated_Scenes

(defstruct (bvh-node
            (:include vec4)
            (:constructor %make-bvh-node (3d-vectors::%vx4 3d-vectors::%vy4 3d-vectors::%vz4 3d-vectors::%vw4 d p l r o))
            (:copier NIL)
            (:predicate NIL))
  (d 0 :type (unsigned-byte 8))
  (p NIL :type (or null bvh-node))
  (l NIL :type (or null bvh-node))
  (r NIL :type (or null bvh-node))
  (o NIL :type T))

(defmethod print-object ((node bvh-node) stream)
  (print-unreadable-object (node stream :type T)
    (let ((o (when (bvh-node-o node) (princ-to-string (bvh-node-o node)))))
      (format stream "~f ~f ~f ~f ~d~@[ ~a~]" (vx4 node) (vy4 node) (vz4 node) (vw4 node) (bvh-node-d node) o))))

(defun make-bvh-node-for (object parent)
  (let ((loc (location object))
        (siz (bsize object)))
    (%make-bvh-node (- (vx loc) (vx siz))
                    (- (vy loc) (vy siz))
                    (+ (vx loc) (vx siz))
                    (+ (vy loc) (vy siz))
                    (1+ (bvh-node-d parent))
                    parent NIL NIL object)))

(defun node-refit-object (node object)
  (let ((x (vx4 node)) (y (vy4 node))
        (z (vz4 node)) (w (vw4 node))
        (loc (location object))
        (siz (bsize object)))
    (setf (vx4 node) (- (vx loc) (vx siz)))
    (setf (vy4 node) (- (vy loc) (vy siz)))
    (setf (vz4 node) (+ (vx loc) (vx siz)))
    (setf (vw4 node) (+ (vy loc) (vy siz)))
    (when (or (/= x (vx4 node))
              (/= y (vy4 node))
              (/= z (vz4 node))
              (/= w (vw4 node)))
      (when (bvh-node-p node)
        (node-refit (bvh-node-p node)))
      T)))

(defun node-fit (node l r)
  (setf (vx4 node) (min (vx4 l) (vx4 r)))
  (setf (vy4 node) (min (vy4 l) (vy4 r)))
  (setf (vz4 node) (max (vz4 l) (vz4 r)))
  (setf (vw4 node) (max (vw4 l) (vw4 r))))

(defun node-refit (node)
  (let ((x (vx4 node)) (y (vy4 node))
        (z (vz4 node)) (w (vw4 node)))
    (node-fit node (bvh-node-l node) (bvh-node-r node))
    (when (or (/= x (vx4 node))
              (/= y (vy4 node))
              (/= z (vz4 node))
              (/= w (vw4 node)))
      (when (bvh-node-p node)
        (node-refit (bvh-node-p node)))
      T)))

(defun node-split (node object)
  (let ((l (make-bvh-node-for (bvh-node-o node) node))
        (r (make-bvh-node-for object node)))
    (setf (bvh-node-o node) NIL)
    (setf (bvh-node-l node) l)
    (setf (bvh-node-r node) r)
    (node-refit node)
    node))

(defun node-contains-p (node object)
  (declare (type vec4 node))
  (declare (optimize speed (safety 0)))
  (let ((loc (location object))
        (siz (bsize object)))
    (declare (type vec2 loc siz))
    (and (<= (vx4 node) (+ (vx loc) (vx siz)))
         (<= (- (vx loc) (vx siz)) (vz4 node))
         (<= (vy4 node) (+ (vy loc) (vy siz)))
         (<= (- (vy loc) (vy siz)) (vw4 node)))))

(defun node-overlaps-p (node region)
  (declare (type vec4 node region))
  (declare (optimize speed (safety 0)))
  (and (<= (vx4 node) (vz4 region))
       (<= (vx4 region) (vz4 node))
       (<= (vy4 node) (vw4 region))
       (<= (vy4 region) (vw4 node))))

(defun node-sub-p (node sub)
  (and (<= (vx4 node) (vx4 sub))
       (<= (vy4 node) (vy4 sub))
       (<= (vz4 sub) (vz4 node))
       (<= (vw4 sub) (vw4 node))))

(defun better-fit (a b object)
  (let ((ca (node-contains-p a object))
        (cb (node-contains-p b object)))
    (cond ((eq ca cb)
           ;; If it's in neither or in both, just see whose centroid we're closer to.
           (let ((ax (/ (+ (vz4 a) (vx4 a)) 2.0))
                 (ay (/ (+ (vw4 a) (vy4 a)) 2.0))
                 (bx (/ (+ (vz4 b) (vx4 b)) 2.0))
                 (by (/ (+ (vw4 b) (vy4 b)) 2.0))
                 (loc (location object)))
             (if (< (+ (expt (- ax (vx loc)) 2)
                       (expt (- ay (vy loc)) 2))
                    (+ (expt (- bx (vx loc)) 2)
                       (expt (- by (vy loc)) 2)))
                 a b)))
          (ca a)
          (cb b))))

(defun node-insert (node object)
  (cond ((bvh-node-o node)
         (node-split node object))
        ((bvh-node-r node)
         (node-insert (better-fit (bvh-node-l node) (bvh-node-r node) object) object))
        (T
         (setf (bvh-node-o node) object)
         (node-refit-object node object)
         node)))

(defun node-sibling (node)
  (let* ((p (bvh-node-p node))
         (l (bvh-node-l p))
         (r (bvh-node-r p)))
    (cond ((eq node l) r)
          ((eq node r) l)
          (T (error "What the fuck?")))))

(defun set-depth (node d)
  (setf (bvh-node-d node) d)
  (unless (bvh-node-o node)
    (set-depth (bvh-node-l node) (1+ d))
    (set-depth (bvh-node-r node) (1+ d))))

(defun node-transfer (target source)
  (setf (vx4 target) (vx4 source))
  (setf (vy4 target) (vy4 source))
  (setf (vz4 target) (vz4 source))
  (setf (vw4 target) (vw4 source))
  (let ((l (bvh-node-l source))
        (r (bvh-node-r source)))
    (setf (bvh-node-l target) l)
    (setf (bvh-node-r target) r)
    (when l
      (setf (bvh-node-p l) target)
      (setf (bvh-node-p r) target))
    (setf (bvh-node-o target) (bvh-node-o source)))
  (set-depth target (bvh-node-d source)))

(defun node-remove (node)
  (let ((p (bvh-node-p node)))
    (cond (p
           (node-transfer p (node-sibling node))
           (when (bvh-node-p p)
             (node-refit (bvh-node-p p)))
           p)
          (T
           (setf (bvh-node-o node) NIL)
           node))))

(defstruct (bvh
            (:constructor make-bvh ())
            (:copier NIL)
            (:predicate NIL))
  (root (%make-bvh-node 0f0 0f0 0f0 0f0 0 NIL NIL NIL NIL) :type bvh-node)
  (table (make-hash-table :test 'eq) :type hash-table))

(defun bvh-insert (bvh object)
  (let ((node (node-insert (bvh-root bvh) object))
        (table (bvh-table bvh)))
    (cond ((eq object (bvh-node-o node))
           (setf (gethash object table) node))
          (T
           (setf (gethash (bvh-node-o (bvh-node-l node)) table) (bvh-node-l node))
           (setf (gethash (bvh-node-o (bvh-node-r node)) table) (bvh-node-r node))))
    object))

(defun bvh-remove (bvh object)
  (let* ((table (bvh-table bvh))
         (node (gethash object table)))
    (when node
      (remhash object table)
      (let ((p (node-remove node)))
        (setf (gethash (bvh-node-o p) table) p)))))

(defun bvh-update (bvh object)
  ;; FIXME: Figure out when to rebalance the tree.
  (let ((node (gethash object (bvh-table bvh))))
    (when node
      (node-refit-object node object))))

(defmethod trial:enter (object (bvh bvh))
  (bvh-insert bvh object))

(defmethod trial:leave (object (bvh bvh))
  (bvh-remove bvh object))

(defmethod trial::clear ((bvh bvh))
  (clrhash (bvh-table bvh))
  (setf (bvh-root bvh) (%make-bvh-node 0f0 0f0 0f0 0f0 0 NIL NIL NIL NIL))
  bvh)

(defun bvh-print (bvh)
  (format T "~&-------------------------")
  (labels ((recurse (node)
             (format T "~&~v@{|  ~}└ ~a" (bvh-node-d node) node)
             (unless (bvh-node-o node)
               (recurse (bvh-node-l node))
               (recurse (bvh-node-r node)))))
    (recurse (bvh-root bvh))))

(defun bvh-lines (bvh)
  (let ((p ()))
    (labels ((depth-color (depth)
               (let ((d (max 0.0 (- 1.0 (/ depth 100)))))
                 (vec 1 d d 0.1)))
             (recurse (node)
               (let ((color (depth-color (bvh-node-d node))))
                 (push (list (vxy_ node) color) p)
                 (push (list (vzy_ node) color) p)
                 (push (list (vxw_ node) color) p)
                 (push (list (vzw_ node) color) p)
                 (push (list (vxy_ node) color) p)
                 (push (list (vxw_ node) color) p)
                 (push (list (vzy_ node) color) p)
                 (push (list (vzw_ node) color) p)
                 (when (bvh-node-l node)
                   (recurse (bvh-node-l node))
                   (recurse (bvh-node-r node))))))
      (recurse (bvh-root bvh)))
    p))

(defun bvh-check (bvh)
  (labels ((recurse (node)
             (cond ((bvh-node-l node)
                    (unless (eq node (bvh-node-p (bvh-node-l node)))
                      (error "The left child~%  ~a~%is not parented to~%  ~a"
                             (bvh-node-l node) node))
                    (unless (eq node (bvh-node-p (bvh-node-r node)))
                      (error "The right child~%  ~a~%is not parented to~%  ~a"
                             (bvh-node-r node) node))
                    (unless (node-sub-p node (bvh-node-l node))
                      (error "The parent node~%  ~a~%does not contain the left child~%  ~a"
                             node (bvh-node-l node)))
                    (unless (node-sub-p node (bvh-node-r node))
                      (error "The parent node~%  ~a~%does not contain the right child~%  ~a"
                             node (bvh-node-r node)))
                    (recurse (bvh-node-l node))
                    (recurse (bvh-node-r node)))
                   ((bvh-node-o node)
                    (unless (eq node (gethash (bvh-node-o node) (bvh-table bvh)))
                      (error "The node~%  ~a~%is not assigned to object~%  ~a~%as it is assigned to~%  ~a"
                             node (bvh-node-o node) (gethash (bvh-node-o node) (bvh-table bvh))))))))
    (recurse (bvh-root bvh)))
  (loop for o being the hash-keys of (bvh-table bvh)
        for n being the hash-values of (bvh-table bvh)
        do (unless (eq o (bvh-node-o n))
             (error "The node~%  ~a~%does not refer to object~%  ~a~%and instead tracks~%  ~a"
                    n o (bvh-node-o n)))))

(defun bvh-refit (bvh)
  (labels ((recurse (node)
             (cond ((bvh-node-l node)
                    (recurse (bvh-node-l node))
                    (recurse (bvh-node-r node))
                    (node-refit node))
                   (T
                    (node-refit-object node (bvh-node-o node))))))
    (recurse (bvh-root bvh))))

(defun call-with-contained (function bvh region)
  (declare (optimize speed))
  (let ((function (etypecase function
                    (symbol (fdefinition function))
                    (function function))))
    (labels ((recurse (node)
               (when (node-overlaps-p node region)
                 (let ((o (bvh-node-o node)))
                   (cond (o
                          (funcall function o))
                         (T
                          (recurse (bvh-node-l node))
                          (recurse (bvh-node-r node))))))))
      (recurse (bvh-root bvh)))))

(defun call-with-overlapping (function bvh object)
  (declare (optimize speed))
  (let ((function (etypecase function
                    (symbol (fdefinition function))
                    (function function))))
    (labels ((recurse (node)
               (when (node-contains-p node object)
                 (let ((o (bvh-node-o node)))
                   (cond (o
                          (funcall function o))
                         (T
                          (recurse (bvh-node-l node))
                          (recurse (bvh-node-r node))))))))
      (recurse (bvh-root bvh)))))

(defmacro do-fitting ((entity bvh region &optional result) &body body)
  (let ((thunk (gensym "THUNK"))
        (regiong (gensym "REGION")))
    `(block NIL
       (flet ((,thunk (,entity)
                ,@body))
         (let ((,regiong ,region))
           (etypecase ,regiong
             (vec2 (let ((,regiong (3d-vectors::%vec4 (vx2 ,regiong) (vy2 ,regiong) (vx2 ,regiong) (vy2 ,regiong))))
                     (declare (dynamic-extent ,regiong))
                     (call-with-contained #',thunk ,bvh ,regiong)))
             (vec4 (call-with-contained #',thunk ,bvh ,regiong))
             (trial:entity (call-with-overlapping #',thunk ,bvh ,regiong)))))
       ,result)))

(defstruct (bvh-iterator
            (:constructor make-bvh-iterator (bvh region))
            (:copier NIL)
            (:predicate NIL))
  (bvh NIL :type bvh)
  (region NIL :type vec4))

(defmethod for:make-iterator ((bvh bvh) &key in)
  (if in
      (make-bvh-iterator bvh in)
      bvh))

(defmethod for:step-functions ((iterator bvh-iterator))
  (declare (optimize speed))
  (let ((node (bvh-root (bvh-iterator-bvh iterator)))
        (region (bvh-iterator-region iterator)))
    (labels ((next-leaf (node child)
               (when node
                 (let ((l (bvh-node-l node))
                       (r (bvh-node-r node)))
                   (cond ((bvh-node-o node)
                          node)
                         ((null child)
                          (if (node-overlaps-p l region)
                              (next-leaf l NIL)
                              (next-leaf node l)))
                         ((eq child l)
                          (if (node-overlaps-p r region)
                              (next-leaf r NIL)
                              (next-leaf node r)))
                         ((eq child r)
                          (next-leaf (bvh-node-p node) node)))))))
      (setf node (next-leaf node NIL))
      (values
       (lambda ()
         (prog1 (bvh-node-o node)
           (setf node (next-leaf (bvh-node-p node) node))))
       (lambda ()
         node)
       (lambda (value)
         (declare (ignore value))
         (error "Not supported"))
       (lambda ())))))

(defmethod for:step-functions ((bvh bvh))
  (declare (optimize speed))
  (let ((node (bvh-root bvh)))
    (labels ((next-leaf (node child)
               (when node
                 (cond ((bvh-node-o node)
                        node)
                       ((null child)
                        (next-leaf (bvh-node-l node) NIL))
                       ((eq child (bvh-node-l node))
                        (next-leaf (bvh-node-r node) NIL))
                       ((eq child (bvh-node-r node))
                        (next-leaf (bvh-node-p node) node))))))
      (setf node (next-leaf node NIL))
      (values
       (lambda ()
         (prog1 (bvh-node-o node)
           (setf node (next-leaf (bvh-node-p node) node))))
       (lambda ()
         node)
       (lambda (value)
         (declare (ignore value))
         (error "Not supported"))
       (lambda ())))))
