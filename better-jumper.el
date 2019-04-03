;;; better-jumper.el --- configurable jump list -*- lexical-binding: t; -*-
;;
;; Author: Bryan Gilbert <http://github/gilbertw1>
;; Maintainer: Bryan Gilbert <bryan@bryan.sh>
;; Created: March 20, 2019
;; Modified: March 26, 2019
;; Version: 1.0.0
;; Keywords: convenience, jump, history, evil
;; Homepage: https://github.com/gilbertw1/better-jumper
;; Package-Requires: ((emacs "25.1") (cl-lib "0.5"))
;;
;; This file is not part of GNU Emacs.

;;; License:
;;
;; This file is part of Better-jumper.
;;
;; Better-jumper is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; Better-jumper is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Better-jumper.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Better-jumper is configurable jump list implementation for Emacs that can be used
;; to easily jump back to previous locations. That provides optional integration with
;; evil.
;;
;; To enable globally:
;;
;;     (require 'better-jumper)
;;
;; See included README.md for more information.
;;
;;; Code:

(defgroup better-jumper nil
  "Better jumper configuration options."
  :prefix "better-jumper"
  :group 'jump)

(defcustom better-jumper-context 'window
  "Determines the context that better jumper operates within."
  :type '(choice (const :tag "Buffer" 'buffer)
                 (other :tag "Window" 'window))
  :group 'better-jumper)

(defcustom better-jumper-new-window-behavior 'copy
  "Determines the behavior when a new window is created."
  :type '(choice (const :tag "Empty jump list" empty)
                 (other :tag "Copy last window" copy))
  :group 'better-jumper)

(defcustom better-jumper-max-length 100
  "The maximum number of jumps to keep track of."
  :type 'integer
  :group 'better-jumper)

(defcustom better-jumper-use-evil-jump-advice t
  "When non-nil, advice is added to add jumps whenever `evil-set-jump' is invoked."
  :type 'boolean
  :group 'better-jumper)

(defcustom better-jumper-pre-jump-hook nil
  "Hooks to run just before jumping to a location in the jump list."
  :type 'hook
  :group 'better-jumper)

(defcustom better-jumper-post-jump-hook nil
  "Hooks to run just after jumping to a location in the jump list."
  :type 'hook
  :group 'better-jumper)

(defcustom better-jumper-ignored-file-patterns '("COMMIT_EDITMSG$" "TAGS$")
  "A list of regexps used to exclude files from the jump list."
  :type '(repeat string)
  :group 'better-jumper)

(defcustom better-jumper-buffer-savehist-size 20
  "The number of buffers to save the jump ring for."
  :type 'integer
  :group 'better-jumper)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar better-jumper--jumping nil
  "Flag inidicating jump in progress to prevent recording unnecessary jumps.")

(defvar better-jumper-switching-perspectives nil
  "Flag indicating if perspective switch is in progress.")

(defvar better-jumper--buffer-targets "\\*\\(new\\|scratch\\)\\*"
  "Regexp to match against `buffer-name' to determine whether it's a valid jump target.")

(defvar-local better-jumper--jump-struct nil
  "Jump struct for current buffer.")

(defvar-local better-jumper--marker-table nil
  "Marker table for current buffer.")

(cl-defstruct better-jumper-jump-list-struct
  ring
  (idx -1))

(defun better-jumper--copy-struct (struct)
  "Return a copy of STRUCT."
  (let ((jump-list (better-jumper--get-struct-jump-list struct))
        (struct-copy (make-better-jumper-jump-list-struct)))
    (setf (better-jumper-jump-list-struct-idx struct-copy) (better-jumper-jump-list-struct-idx struct))
    (setf (better-jumper-jump-list-struct-ring struct-copy) (ring-copy jump-list))
    struct-copy))

(defun better-jumper--get-current-context ()
  "Get current context item. Either current window or buffer."
  (cond ((eq better-jumper-context 'buffer)
         (current-buffer))
        ((eq better-jumper-context 'window)
         (frame-selected-window))))

(defun better-jumper--set-window-struct (window struct)
  "Set jump struct for WINDOW to STRUCT."
   (set-window-parameter window 'better-jumper-struct struct))

(defun better-jumper--set-buffer-struct (buffer struct)
  "Set jump struct for BUFFER to STRUCT."
   (setf (buffer-local-value 'better-jumper--jump-struct buffer) struct))

(defun better-jumper--set-struct (context struct)
  "Set jump struct for CONTEXT to STRUCT."
  (cond ((eq better-jumper-context 'buffer)
         (better-jumper--set-buffer-struct context struct))
        ((eq better-jumper-context 'window)
         (better-jumper--set-window-struct context struct))))

(defun better-jumper--get-buffer-struct (&optional buffer)
  "Get current jump struct for BUFFER.
Creates and sets jump struct if one does not exist. buffer if BUFFER parameter
is missing."
  (let* ((buffer (or buffer (current-buffer)))
         (jump-struct (buffer-local-value 'better-jumper--jump-struct buffer)))
    (unless jump-struct
      (setq jump-struct (make-better-jumper-jump-list-struct))
      (better-jumper--set-buffer-struct buffer jump-struct))
    jump-struct))

(defun better-jumper--get-window-struct (&optional window)
  "Get current jump struct for WINDOW.
Creates and sets jump struct if one does not exist. buffer if WINDOW parameter
is missing."
  (let* ((window (or window (frame-selected-window)))
         (jump-struct (window-parameter window 'better-jumper-struct)))
    (unless jump-struct
      (setq jump-struct (make-better-jumper-jump-list-struct))
      (better-jumper--set-struct window jump-struct))
    jump-struct))

(defun better-jumper--get-struct (&optional context)
  "Get current jump struct for CONTEXT.
Creates and sets jump struct if one does not exist. Uses current window or
buffer if CONTEXT parameter is missing."
  (if (eq better-jumper-context 'buffer)
      (better-jumper--get-buffer-struct context)
    (better-jumper--get-window-struct context)))

(defun better-jumper--make-key ()
  "Generate random unique key."
  (let ((key "")
        (alnum "abcdefghijklmnopqrstuvwxyz0123456789"))
    (dotimes (_ 6 key)
      (let* ((i (% (abs (random)) (length alnum))))
        (setq key (concat key (substring alnum i (1+ i))))))))

(defun better-jumper--set-window-marker-table (window table)
  "Set marker table for WINDOW to TABLE."
  (set-window-parameter window 'better-jumper-marker-table table))

(defun better-jumper--set-buffer-marker-table (buffer table)
  "Set marker table for BUFFER to TABLE."
  (setf (buffer-local-value 'better-jumper--marker-table buffer) table))

(defun better-jumper--set-marker-table (context table)
  "Set marker table for CONTEXT to TABLE."
  (cond ((eq better-jumper-context 'buffer)
         (better-jumper--set-buffer-marker-table context table))
        ((eq better-jumper-context 'window)
         (better-jumper--set-window-marker-table context table))))

(defun better-jumper--get-buffer-marker-table (&optional buffer)
  "Get current marker table for BUFFER.
Creates and sets marker table if one does not exist. buffer if BUFFER parameter
is missing."
  (let* ((buffer (or buffer (current-buffer)))
         (marker-table (buffer-local-value 'better-jumper--marker-map buffer)))
    (unless marker-table
      (setq marker-table (make-hash-table))
      (better-jumper--set-marker-table buffer marker-table))
    marker-table))

(defun better-jumper--get-window-marker-table (&optional window)
  "Get marker table for WINDOW.
Creates and sets marker table if one does not exist. buffer if WINDOW parameter
is missing."
  (let* ((window (or window (frame-selected-window)))
         (marker-table (window-parameter window 'better-jumper-marker-table)))
    (unless marker-table
      (setq marker-table (make-hash-table))
      (better-jumper--set-marker-table window marker-table))
    marker-table))

(defun better-jumper--get-marker-table (&optional context)
  "Get current marker map for CONTEXT.
Creates and adds marker table if one does not exist. Uses current window or
buffer if CONTEXT parameter is missing."
  (if (eq better-jumper-context 'buffer)
      (better-jumper--get-buffer-marker-table context)
    (better-jumper--get-window-marker-table context)))

(defun better-jumper--get-struct-jump-list (struct)
  "Gets and potentially initialize jumps for STRUCT."
  (let ((ring (better-jumper-jump-list-struct-ring struct)))
    (unless ring
      (setq ring (make-ring better-jumper-max-length))
      (setf (better-jumper-jump-list-struct-ring struct) ring))
    ring))

(defun better-jumper--get-jump-list (&optional context)
  "Gets jump list for CONTEXT.
Uses the current context if CONTEXT is nil."
  (let ((struct (better-jumper--get-struct context)))
    (better-jumper--get-struct-jump-list struct)))

(defun better-jumper--jump (idx shift &optional context)
  "Jump from position IDX using SHIFT on CONTEXT.
Uses current context if CONTEXT is nil."
  (let ((jump-list (better-jumper--get-jump-list context)))
    (setq idx (+ idx shift))
    (let* ((size (ring-length jump-list)))
      (when (and (< idx size) (>= idx 0))
        ;; actual jump
        (run-hooks 'better-jumper-pre-jump-hook)
        (let* ((marker-table (better-jumper--get-marker-table context))
               (place (ring-ref jump-list idx))
               (file-name (nth 0 place))
               (pos (nth 1 place))
               (marker-key (nth 2 place))
               (marker (gethash marker-key marker-table)))
          (setq better-jumper--jumping t)
          (if (string-match-p better-jumper--buffer-targets file-name)
              (switch-to-buffer file-name)
            (find-file file-name))
          (setq better-jumper--jumping nil)
          (if marker
              (goto-char marker)
            (goto-char pos)
            (puthash marker-key (point-marker) marker-table))
          (setf (better-jumper-jump-list-struct-idx (better-jumper--get-struct context)) idx)
          (run-hooks 'better-jumper-post-jump-hook))))))

(defun better-jumper--push (&optional context)
  "Pushes the current cursor/file position to the jump list for CONTEXT.
Uses current context if CONTEXT is nil."
  (let ((jump-list (better-jumper--get-jump-list context))
        (marker-table (better-jumper--get-marker-table context))
        (file-name (buffer-file-name))
        (buffer-name (buffer-name))
        (current-marker (point-marker))
        (current-point (point))
        (first-point nil)
        (first-file-name nil)
        (excluded nil))
    (when (and (not file-name)
                 (string-match-p better-jumper--buffer-targets buffer-name))
        (setq file-name buffer-name))
      (when file-name
        (dolist (pattern better-jumper-ignored-file-patterns)
          (when (string-match-p pattern file-name)
            (setq excluded t)))
        (unless excluded
          (unless (ring-empty-p jump-list)
            (setq first-point (nth 1 (ring-ref jump-list 0)))
            (setq first-file-name (nth 2 (ring-ref jump-list 0))))
          (unless (and (equal first-point current-point)
                       (equal first-file-name file-name))
            (let ((key (better-jumper--make-key)))
              (puthash key current-marker marker-table)
              (ring-insert jump-list `(,file-name ,current-point ,key))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;   PUBLIC FUNCTIONS    ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun better-jumper-set-jump (&optional pos)
  "Set jump point at POS.
POS defaults to point."
  (unless (or (region-active-p)
              (and (boundp 'evil-visual-state-p)
                   (evil-visual-state-p)))
    (push-mark pos t))

  (unless better-jumper--jumping
    ;; clear out intermediary jumps when a new one is set
    (let* ((struct (better-jumper--get-struct))
           (jump-list (better-jumper--get-struct-jump-list struct))
           (idx (better-jumper-jump-list-struct-idx struct)))
      (cl-loop repeat idx
               do (ring-remove jump-list))
      (setf (better-jumper-jump-list-struct-idx struct) -1))
    (save-excursion
      (when pos
        (goto-char pos))
      (better-jumper--push))))

;;;###autoload
(defun better-jumper-jump-backward (&optional count)
  "Jump backward COUNT positions to previous location in jump list.
If COUNT is nil then defaults to 1."
  (interactive)
  (let* ((count (or count 1))
         (struct (better-jumper--get-struct))
         (idx (better-jumper-jump-list-struct-idx struct)))
    (when (= idx -1)
      (setq idx 0)
      (setf (better-jumper-jump-list-struct-idx struct) 0)
      (better-jumper--push))
    (better-jumper--jump idx count)))

;;;###autoload
(defun better-jumper-jump-forward (&optional count)
  "Jump forward COUNT positions to location in jump list.
If COUNT is nil then defaults to 1."
  (interactive)
  (let* ((count (or count 1))
         (struct (better-jumper--get-struct))
         (idx (better-jumper-jump-list-struct-idx struct)))
        (when (= idx -1)
          (setq idx 0)
          (setf (better-jumper-jump-list-struct-idx struct) 0)
          (better-jumper--push))
        (better-jumper--jump idx (- 0 count))))

;;;###autoload
(defun better-jumper-get-jumps (window-or-buffer)
  "Get jumps for WINDOW-OR-BUFFER.
The argument should be either a window or buffer depending on the context."
  (let* ((struct (better-jumper--get-struct window-or-buffer))
         (struct-copy (better-jumper--copy-struct struct)))
    struct-copy))

;;;###autoload
(defun better-jumper-set-jumps (window-or-buffer jumps)
  "Set jumps to JUMPS for WINDOW-OR-BUFFER.
The argument should be either a window or buffer depending on the context."
  (let ((struct-copy (better-jumper--copy-struct jumps)))
    (better-jumper--set-struct window-or-buffer struct-copy)))

;;;;;;;;;;;;;;;;;;
;;;   HOOKS    ;;;
;;;;;;;;;;;;;;;;;;

(defun better-jumper--before-persp-deactivate (&rest args)
  "Save jump state when a perspective is deactivated. Ignore ARGS."
  (ignore args)
  (setq better-jumper-switching-perspectives t))

(defun better-jumper--on-persp-activate (&rest args)
  "Restore jump state when a perspective is activated. Ignore ARGS."
  (ignore args)
  (setq better-jumper-switching-perspectives nil))

(with-eval-after-load 'persp-mode
  (add-hook 'persp-before-deactivate-functions #'better-jumper--before-persp-deactivate)
  (add-hook 'persp-activated-functions #'better-jumper--on-persp-activate))

(defun better-jumper--window-configuration-hook (&rest args)
  "Run on window configuration change (Ignore ARGS).
Cleans up deleted windows and copies history to newly created windows."
  (ignore args)
  (when (and (eq better-jumper-context 'window)
             (eq better-jumper-new-window-behavior 'copy)
             (not better-jumper-switching-perspectives))
    (let* ((window-list (window-list-1 nil nil t))
           (curr-window (selected-window))
           (source-jump-struct (better-jumper--get-struct curr-window))
           (source-jump-list (better-jumper--get-struct-jump-list source-jump-struct)))
      (unless (ring-empty-p source-jump-list))
        (dolist (window window-list)
          (let* ((target-jump-struct (better-jumper--get-struct window))
                 (target-jump-list (better-jumper--get-struct-jump-list target-jump-struct)))
            (when (ring-empty-p target-jump-list)
              (setf (better-jumper-jump-list-struct-idx target-jump-struct) (better-jumper-jump-list-struct-idx source-jump-struct))
              (setf (better-jumper-jump-list-struct-ring target-jump-struct) (ring-copy source-jump-list))))))))

(add-hook 'window-configuration-change-hook #'better-jumper--window-configuration-hook)

(with-eval-after-load 'evil
  (defadvice evil-set-jump (before better-jumper activate)
    (when better-jumper-use-evil-jump-advice
      (better-jumper-set-jump))))

(push '(better-jumper-struct . writable) window-persistent-parameters)

(provide 'better-jumper)
;;; better-jumper.el ends here
