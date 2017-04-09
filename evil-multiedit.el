;;; evil-multiedit.el --- multiple cursors for evil-mode
;;
;; Copyright (C) 2016 Henrik Lissner
;;
;; Author: Henrik Lissner <http://github/hlissner>
;; Maintainer: Henrik Lissner <henrik@lissner.net>
;; Created: February 20, 2016
;; Modified: April 8, 2017
;; Version: 1.3.4
;; Keywords: multiple cursors, editing, iedit
;; Homepage: https://github.com/hlissner/evil-multiedit
;; Package-Requires: ((emacs "24.4") (evil "1.2.12") (iedit "0.97") (cl-lib "0.5"))
;;
;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; This plugin tries to fill that multi-cursor shaped gap in your heart, by integrating
;; iedit-mode into evil-mode.
;;
;; Usage
;;
;;   Evil-multiedit *does not bind any new keys*, so you will have to yourself.
;;   Here is my recommended configuration (use `evil-multiedit-default-keybinds'
;;   to bind them automatically):
;;
;;     ;; Highlights all matches of the selection in the buffer.
;;     (define-key evil-visual-state-map "R" 'evil-multiedit-match-all)
;;
;;     ;; Match the word under cursor (i.e. make it an edit region). Consecutive
;;     ;; presses will incrementally add the next unmatched match.
;;     (define-key evil-normal-state-map (kbd "M-d") 'evil-multiedit-match-and-next)
;;     ;; Match selected region.
;;     (define-key evil-visual-state-map (kbd "M-d") 'evil-multiedit-and-next)
;;     ;; Insert marker at point
;;     (define-key evil-insert-state-map (kbd "M-d") 'evil-multiedit-toggle-marker-here)
;;
;;     ;; Same as M-d but in reverse.
;;     (define-key evil-normal-state-map (kbd "M-D") 'evil-multiedit-match-and-prev)
;;     (define-key evil-visual-state-map (kbd "M-D") 'evil-multiedit-and-prev)
;;
;;     ;; OPTIONAL: If you prefer to grab symbols rather than words, use
;;     ;; `evil-multiedit-match-symbol-and-next` (or prev).
;;
;;     ;; Restore the last group of multiedit regions.
;;     (define-key evil-visual-state-map (kbd "C-M-D") 'evil-multiedit-restore)
;;
;;     ;; RET will toggle the region under the cursor
;;     (define-key evil-multiedit-state-map (kbd "RET") 'evil-multiedit-toggle-or-restrict-region)
;;
;;     ;; ...and in visual mode, RET will disable all fields outside the selected region
;;     (define-key evil-motion-state-map (kbd "RET") 'evil-multiedit-toggle-or-restrict-region)
;;
;;     ;; For moving between edit regions
;;     (define-key evil-multiedit-state-map (kbd "C-n") 'evil-multiedit-next)
;;     (define-key evil-multiedit-state-map (kbd "C-p") 'evil-multiedit-prev)
;;     (define-key evil-multiedit-insert-state-map (kbd "C-n") 'evil-multiedit-next)
;;     (define-key evil-multiedit-insert-state-map (kbd "C-p") 'evil-multiedit-prev)
;;
;;     ;; Ex command that allows you to invoke evil-multiedit with a regular
;;     ;; expression, e.g.
;;     (evil-ex-define-cmd "ie[dit]" 'evil-multiedit-ex-match)
;;
;;; Code:

(defvar iedit-occurrence-keymap-default (make-sparse-keymap))
(defvar iedit-overlay-priority 0)

(require 'evil)
(require 'iedit)
(require 'cl-lib)

(defgroup evil-multiedit nil
  "Multiple cursors for `evil-mode' using iedit."
  :prefix "evil-multiedit-"
  :group 'evil)

(defcustom evil-multiedit-dwim-motion-keys t
  "Whether or not to modify evil's motion keys to act differently when the
cursor is inside multiedit regions. Must be set before evil-multiedit is
loaded."
  :group 'evil-multiedit
  :type 'boolean)

(defcustom evil-multiedit-match-whitespace t
  "If non-nil allow matching against whitespace characters, where
whitespace is defined by the active major-mode's syntax
table."
  :group 'evil-multiedit
  :type 'boolean)

(defcustom evil-multiedit-match-punctuation t
  "If non-nil allow matching against punctuation characters,
where punctuation is defined by the active major-mode's syntax
table."
  :group 'evil-multiedit
  :type 'boolean)

(defcustom evil-multiedit-ignore-indent-and-trailing t
  "When you match forward whitespace and this is non-nil, leading and trailing
whitespace will be ignored."
  :group 'evil-multiedit
  :type 'boolean)

(defcustom evil-multiedit-use-symbols evil-symbol-word-search
  "Grab the symbol under cursor if evil-multiedit is invoked from
normal mode. If this is nil, words are used instead."
  :group 'evil-multiedit
  :type 'boolean)

(defcustom evil-multiedit-smart-match-boundaries t
  "If non-nil, multiedit tries to make sure match boundaries match on successive
matches when invoked from normal mode. E.g. 'evil-multiedit-match' will not
match 'evil-multiedit-match-all', or 'i' will only match 'i' and not every
individual i in, say, 'ignition'.

If evil-multiedit is invoked from visual mode, this is ignored."
  :group 'evil-multiedit
  :type 'boolean)

(defcustom evil-multiedit-store-in-search-history nil
  "If non-nil, highlighted occurrences are stored in `regexp-search-ring', so
that after exiting iedit `evil-search-next' and `evil-search-previous' (usually
n and N) use the last occurrence as if it were the last string in the search
history."
  :group 'evil-multiedit
  :type 'boolean)

(defcustom evil-multiedit-scope 'buffer
  "How far evil-multiedit should look for additional matches. Accepts 'visible,
or anything that `bounds-of-thing-at-point' accept, such as 'defun, 'sexp or
'email. If 'buffer (the default), evil-multiedit will search the whole buffer."
  :group 'evil-multiedit
  :type 'symbol)
(make-variable-buffer-local 'evil-multiedit-scope)

(defcustom evil-multiedit-follow-matches nil
  "If non-nil, cursor will jump to each new match on
`evil-multiedit-match-and-next' and `evil-multiedit-match-and-prev' (and its
symbol variants)."
  :group 'evil-multiedit
  :type 'boolean)

(defcustom evil-multiedit-marker
  (propertize "|" 'face '(:inverse-video t))
  "The string to display in place of empty markers."
  :group 'evil-multiedit
  :type 'string)

(defvar evil-multiedit--pt-end nil "The end of the first match")
(defvar evil-multiedit--pt-beg nil "The beginning of the first region")
(defvar evil-multiedit--pt-index (cons 1 1) "The forward/backward search indices")

(defvar evil-multiedit--dont-recall nil)
(defvar evil-multiedit--last-markers '() "List of markers from last multiedit.")
(make-variable-buffer-local 'evil-multiedit--last-markers)

(defvar evil-multiedit--marker nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun evil-multiedit-restore ()
  "Restore the last group of multiedit regions."
  (interactive)
  (iedit-mode 4)
  (when evil-multiedit--last-markers
    (let ((beg-list (mapcar (lambda (m) (marker-position m)) evil-multiedit--last-markers)))
      (save-excursion
        (mapc (lambda (ov)
                (let ((beg (overlay-start ov)))
                  (unless (memq beg beg-list)
                    (goto-char beg)
                    (iedit-toggle-selection))))
              iedit-occurrences-overlays))))
  (evil-multiedit-state))

;;;###autoload
(defun evil-multiedit-match-all ()
  "Highlight all matches of the current selection (or symbol under pointer) as
multiedit regions."
  (interactive)
  (if (fboundp 'ahs-clear) (ahs-clear))
  (setq evil-multiedit--dont-recall t)
  (evil-multiedit--start-regexp (car (evil-multiedit--get-occurrence))
                                (point-min) (point-max)))

;;;###autoload (autoload 'evil-multiedit-match-symbol-and-next "evil-multiedit" nil t)
(evil-define-command evil-multiedit-match-symbol-and-next (&optional count)
  "Same as `evil-multiedit-match-and-next' if invoked from visual mode. From
normal mode, it grabs whole symbols rather than words."
  :jump t
  (interactive "<c>")
  (let ((evil-multiedit-use-symbols t))
    (evil-multiedit-match-and-next count)))

;;;###autoload (autoload 'evil-multiedit-match-symbol-and-prev "evil-multiedit" nil t)
(evil-define-command evil-multiedit-match-symbol-and-prev (&optional count)
  "Same as `evil-multiedit-match-and-prev' if invoked from visual mode. From
normal mode, it grabs whole symbols rather than words."
  :jump t
  (interactive "<c>")
  (evil-multiedit-match-symbol-and-next (or (and count (* -1 count)) -1)))

;;;###autoload
(defun evil-multiedit-toggle-marker-here ()
  "Toggle an arbitrary multiedit region at point."
  (interactive)
  (when (and iedit-occurrences-overlays
             (> (iedit-occurrence-string-length) 0))
    (evil-multiedit--cleanup))
  (let ((points (cond ((eq (evil-visual-type) 'block)
                       (mapcar 'overlay-start evil-visual-block-overlays))
                      (t (list (point))))))
    (dolist (point points)
      (let ((ov (iedit-find-overlay-in-region point point 'iedit-occurrence-overlay-name)))
        (if ov
            (progn
              (setq iedit-occurrences-overlays (delete ov iedit-occurrences-overlays))
              (delete-overlay ov))
          (let ((ov (iedit-make-occurrence-overlay point point)))
            (unless ov
              (error "Failed to create marker"))
            (push ov iedit-occurrences-overlays)
            (dolist (prop '(insert-in-front-hooks insert-behind-hooks modification-hooks))
              (let ((old (overlay-get ov prop)))
                (overlay-put ov prop (append old '(evil-multiedit--update-occurrences)))))
            (setq evil-multiedit--marker t)
            (overlay-put ov 'before-string evil-multiedit-marker))))))
  (if iedit-occurrences-overlays
      (unless (evil-multiedit-state-p)
        (evil-multiedit-state))
    (evil-multiedit--cleanup)))

;;;###autoload (autoload 'evil-multiedit-match-and-next "evil-multiedit" nil t)
(evil-define-command evil-multiedit-match-and-next (&optional count)
  "Marks the word at point (or, if in visual mode, the selection), then marks
the next matches on consecutive runs of this function. Jumps to next region if
`evil-multiedit-follow-matches' is non-nil.

Note: the matching behavior differs depending on if it was invoked from normal
or visual mode.

  + From normal mode: `evil-multiedit-use-symbols' determines how to grab the
    match under the cursor.
  + From visual mode, word and symbol boundaries are ignored, allowing for
    in-word matches."
  (interactive "<c>")
  (let ((forward-p (or (null count) (> count 0)))
        (count (or (and count (abs count)) 1)))
    (dotimes (i count)
      (cond (iedit-mode
             (let ((bounds (evil-multiedit--scope))
                   (origin (point))
                   (start (if forward-p evil-multiedit--pt-end evil-multiedit--pt-beg))
                   (whitespace-p (string-match-p "\\`\\s-+\\'" iedit-initial-string-local))
                   beg end)
               (goto-char (+ start (if forward-p 1 -1)))
               (unless (re-search-forward iedit-initial-string-local
                                          (if forward-p (cdr bounds) (car bounds))
                                          t (if forward-p 1 -1))
                 (goto-char origin)
                 (user-error "No more matches"))
               ;; Skip leading and trailing whitespace, if possible
               (while (and whitespace-p evil-multiedit-ignore-indent-and-trailing
                           (or (<= (point) (save-excursion (back-to-indentation) (point)))
                               (>  (point) (save-match-data (save-excursion (evil-last-non-blank) (point)))))
                           (re-search-forward iedit-initial-string-local
                                              (if forward-p (cdr bounds) (car bounds))
                                              t (if forward-p 1 -1))))
               (setq beg (match-beginning 0)
                     end (match-end 0))
               ;; Check for an overlay, if none exist, create one
               (unless (or (iedit-find-overlay-at-point beg 'iedit-occurrence-overlay-name)
                           (iedit-find-overlay-at-point end 'iedit-occurrence-overlay-name))
                 (push (iedit-make-occurrence-overlay beg end)
                       iedit-occurrences-overlays))
               ;; Remember for next time
               (setq evil-multiedit--pt-beg (min beg evil-multiedit--pt-beg)
                     evil-multiedit--pt-end (max end evil-multiedit--pt-end))
               (goto-char (if evil-multiedit-follow-matches beg origin))))
            (t
             (let* ((occurrence-info (evil-multiedit--get-occurrence))
                    (occurrence (car occurrence-info))
                    (beg (nth 1 occurrence-info))
                    (end (nth 2 occurrence-info)))
               (if (and beg end)
                   (progn
                     (setq evil-multiedit--pt-beg beg
                           evil-multiedit--pt-end end)
                     (evil-normal-state)
                     (save-excursion
                       (evil-multiedit--start-regexp occurrence beg end)
                       (let ((pattern (evil-ex-make-search-pattern occurrence)))
                         (when evil-multiedit-store-in-search-history
                           (setq evil-ex-search-pattern pattern))
                         (let ((evil-ex-search-pattern pattern))
                           (evil-ex-find-next nil nil t)))))
                 (user-error "Can't mark anything")))))))
  (length iedit-occurrences-overlays))

;;;###autoload (autoload 'evil-multiedit-match-and-prev "evil-multiedit" nil t)
(evil-define-command evil-multiedit-match-and-prev (&optional count)
  "The backwards version of `evil-multiedit-match-and-next'"
  :jump t
  (interactive "<c>")
  (evil-multiedit-match-and-next (or (and count (* -1 count)) -1)))

;;;###autoload
(defun evil-multiedit-toggle-or-restrict-region (&optional beg end)
  "If in visual mode, restrict the multiedit regions to the selected region.
i.e. disable all regions outside the selection. If in any other mode, toggle the
multiedit region beneath the cursor, if one exists."
  (interactive)
  (if (and iedit-mode (iedit-current-occurrence-string))

      (cond ((or (evil-visual-state-p)
                 (and beg end))
             (let ((current-prefix-arg '(4))
                   (beg (or beg (region-beginning)))
                   (end (or end (region-end))))
               (iedit-done)
               (call-interactively 'iedit-mode)
               (save-excursion (iedit-restrict-region beg end))
               (evil-previous-line)))
            (t (iedit-toggle-selection)))
    (call-interactively 'evil-ret)))

;;;###autoload
(defun evil-multiedit-next ()
  "Jump to the next multiedit region."
  (interactive)
  (evil-multiedit--cycle +1))

;;;###autoload
(defun evil-multiedit-prev ()
  "Jump to the previous multiedit region."
  (interactive)
  (evil-multiedit--cycle -1))

;;;###autoload
(defun evil-multiedit-abort (&optional inhibit-normal)
  "Clear all multiedit regions, clean up and revert to normal state."
  (interactive)
  (mapc (lambda (m) (set-marker m nil)) evil-multiedit--last-markers)
  (if evil-multiedit--dont-recall
      (setq evil-multiedit--last-markers '())
    (mapc (lambda (ov)
            (let ((m (make-marker)))
              (set-marker-insertion-type m t)
              (set-marker m (overlay-start ov))
              (push m evil-multiedit--last-markers)))
          iedit-occurrences-overlays))
  (iedit-done)
  (unless inhibit-normal
    (evil-normal-state)))

;;;###autoload (autoload 'evil-multiedit-ex-match "evil-multiedit" nil t)
(evil-define-command evil-multiedit-ex-match (&optional beg end bang regexp)
  "Ex command for invoking evil-multiedit with a regular expression. The
selected area is the boundary for matches. If BANG, invert
`evil-multiedit-smart-match-boundaries'."
  (interactive "<r><!><a>")
  (evil-multiedit-abort)
  (let ((evil-multiedit-smart-match-boundaries
         (if bang
             (not evil-multiedit-smart-match-boundaries)
           evil-multiedit-smart-match-boundaries)))
    (if regexp
        (evil-multiedit--start-regexp regexp beg end)
      (evil-multiedit-restore)
      (when (and beg end)
        (evil-multiedit-toggle-or-restrict-region beg end)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun evil-multiedit--cycle (n)
  (setq iedit-occurrences-overlays (cl-sort iedit-occurrences-overlays '< :key 'overlay-start))
  (let* ((point (point))
         (occurrence
          (cl-find-if (if (> n 0)
                          (lambda (beg) (> beg point))
                        (lambda (end) (< end point)))
                      iedit-occurrences-overlays :key
                      (if (> n 0) 'overlay-start 'overlay-end))))
    (if occurrence
        (goto-char (overlay-start occurrence))
      (user-error "No more occurrences"))))

(defun evil-multiedit--update-occurrences (&rest _)
  (when (if evil-multiedit--marker
            (> (iedit-occurrence-string-length) 0)
          (= (iedit-occurrence-string-length) 0))
    (let ((ov-str (unless evil-multiedit--marker evil-multiedit-marker)))
      (dolist (ov iedit-occurrences-overlays)
        (overlay-put ov 'before-string ov-str))
      (setq evil-multiedit--marker (not evil-multiedit--marker)))))

(defun evil-multiedit--scope ()
  (if (eq evil-multiedit-scope 'visible)
      (cons (window-start) (window-end))
    (or (bounds-of-thing-at-point evil-multiedit-scope)
        (and (null evil-multiedit-scope)
             (bounds-of-thing-at-point 'buffer))
        (error "Invalid/empty scope (%s), check `evil-multiedit-scope'"
               evil-multiedit-scope))))

(defun evil-multiedit--get-occurrence ()
  (save-match-data
    (let (regexp bounds)
      (cond ((evil-visual-state-p)
             (setq regexp
                   (regexp-quote (buffer-substring-no-properties
                                  evil-visual-beginning evil-visual-end)))
             (setq bounds (cons evil-visual-beginning evil-visual-end)))
            ((or (and evil-multiedit-match-whitespace
                      (looking-at "\\s-+"))
                 (and evil-multiedit-match-punctuation
                      (looking-at "\\s.+")))
             (setq regexp (regexp-quote
                           (match-string-no-properties 0)))
             (setq bounds (cons (match-beginning 0) (match-end 0))))
            ((and evil-multiedit-use-symbols
                  (bounds-of-thing-at-point 'symbol))
             (setq regexp
                   (format "\\_<%s\\_>"
                           (regexp-quote (thing-at-point 'symbol t))))
             (setq bounds (bounds-of-thing-at-point 'symbol)))
            ((bounds-of-thing-at-point 'word)
             (setq regexp
                   (format "\\_<%s\\_>"
                           (regexp-quote (thing-at-point 'word t))))
             (setq bounds (bounds-of-thing-at-point 'word))))
      (list regexp (car bounds) (cdr bounds)))))

(defun evil-multiedit--start (obeg oend &optional beg end)
  (let* ((occurrence (buffer-substring-no-properties obeg oend))
         (sym-p (string-match-p "^[^a-zA-Z0-9]$" occurrence)))
    (when occurrence
      (setq occurrence (regexp-quote occurrence))
      (when (and evil-multiedit-smart-match-boundaries
                 (not sym-p))
        (when (and (goto-char (1- obeg))
                   (looking-at "[^a-zA-Z0-9]"))
          (setq occurrence (concat "\\_<" occurrence)))
        (when (and (goto-char oend)
                   (looking-at "[^a-zA-Z0-9]"))
          (setq occurrence (concat occurrence "\\_>"))))
      (evil-multiedit--start-regexp occurrence (or beg obeg) (or end oend)))))

(defun evil-multiedit--start-regexp (regexp &optional beg end)
  (setq iedit-initial-string-local regexp)
  (when evil-multiedit-store-in-search-history
    (isearch-update-ring regexp t))
  (iedit-start regexp beg end)
  (evil-multiedit-state)
  regexp)

(defun evil-multiedit--cleanup ()
  (setq evil-multiedit--dont-recall nil
        evil-multiedit--pt-end nil
        evil-multiedit--pt-beg nil
        evil-multiedit--pt-index (cons 1 1)
        iedit-occurrences-overlays nil))

(defmacro evil-multiedit--switch-to-insert-state-after (command &optional interactive)
  "Call COMMAND and switch to iedit-insert state. If INTERACTIVE is non-nil then
COMMAND is called interactively."
  `(progn
     (if ,interactive
         (call-interactively ',command)
       (funcall ',command))
     ;; required to correctly update the cursors
     (evil-multiedit-state)
     (evil-multiedit-insert-state)))

(defun evil-multiedit--goto-overlay-start ()
  "Return the position of the start of the current overlay."
  (let ((overlay (iedit-find-current-occurrence-overlay)))
    (if overlay
        (goto-char (overlay-start overlay))
      (call-interactively 'evil-digit-argument-or-evil-beginning-of-line))))

(defun evil-multiedit--goto-overlay-end ()
  "Return the position of the end of the current overlay."
  (let ((overlay (iedit-find-current-occurrence-overlay)))
    (if overlay
        (goto-char (overlay-end overlay))
      (call-interactively 'evil-end-of-line))))

(defun evil-multiedit--beginning-of-line ()
  "Go to the beginning of the current overlay."
  (interactive)
  (evil-multiedit--goto-overlay-start))

(defun evil-multiedit--end-of-line ()
  "Go to the beginning of the current overlay."
  (interactive)
  (evil-multiedit--goto-overlay-end))

(defun evil-multiedit--append-line ()
  "Put the point at then end of current overlay and switch to iedit-insert
state."
  (interactive)
  (if (iedit-find-current-occurrence-overlay)
      (evil-multiedit--switch-to-insert-state-after evil-multiedit--goto-overlay-end)
    (evil-multiedit--switch-to-insert-state-after evil-append-line t)))

(defun evil-multiedit--insert-line ()
  "Put the point at then end of current overlay and switch to iedit-insert
state."
  (interactive)
  (evil-multiedit--switch-to-insert-state-after
   evil-multiedit--goto-overlay-start))

(defun evil-multiedit--change ()
  "Wipe all the occurrences and switch in `iedit-insert state'"
  (interactive)
  (evil-multiedit--switch-to-insert-state-after evil-change t))

(defun evil-multiedit--append ()
  "Append and switch to `iedit-insert state'"
  (interactive)
  (evil-multiedit--switch-to-insert-state-after evil-append t))

(defun evil-multiedit--open-below ()
  "Insert new line below and switch to `iedit-insert state'"
  (interactive)
  (evil-multiedit--switch-to-insert-state-after evil-open-below t))

(defun evil-multiedit--open-above ()
  "Insert new line above and switch to `iedit-insert state'"
  (interactive)
  (evil-multiedit--switch-to-insert-state-after evil-open-above t))

(defun evil-multiedit--visual-line ()
  "Visually select edit region."
  (interactive)
  (let ((ov (iedit-find-current-occurrence-overlay)))
    (if ov
        (evil-visual-make-region (overlay-start ov) (1- (overlay-end ov)) 'exclusive)
      (call-interactively 'evil-visual-line))))

(defun evil-multiedit--substitute ()
  "Wipe all the occurrences and switch in `iedit-insert state'"
  (interactive)
  (if (not (iedit-find-current-occurrence-overlay))
      (call-interactively 'evil-change-line)
    (iedit-delete-occurrences)
    (evil-multiedit-insert-state)))

(defun evil-multiedit--paste-replace (count)
  "Replace the selection with the yanked text."
  (interactive "P")
  (iedit-delete-occurrences)
  (evil-paste-before count))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun evil-multiedit-default-keybinds ()
  "Sets up the default keybindings for `evil-multiedit'."
  (define-key evil-visual-state-map "R" 'evil-multiedit-match-all)
  (define-key evil-normal-state-map (kbd "M-d") 'evil-multiedit-match-symbol-and-next)
  (define-key evil-visual-state-map (kbd "M-d") 'evil-multiedit-match-and-next)
  (define-key evil-normal-state-map (kbd "M-D") 'evil-multiedit-match-symbol-and-prev)
  (define-key evil-visual-state-map (kbd "M-D") 'evil-multiedit-match-and-prev)
  (define-key evil-insert-state-map (kbd "M-d") 'evil-multiedit-toggle-marker-here)
  (define-key evil-visual-state-map (kbd "C-M-D") 'evil-multiedit-restore)
  (define-key evil-motion-state-map (kbd "RET") 'evil-multiedit-toggle-or-restrict-region)
  (define-key evil-multiedit-state-map (kbd "RET") 'evil-multiedit-toggle-or-restrict-region)
  (define-key evil-multiedit-state-map (kbd "C-n") 'evil-multiedit-next)
  (define-key evil-multiedit-state-map (kbd "C-p") 'evil-multiedit-prev)
  (define-key evil-multiedit-insert-state-map (kbd "C-n") 'evil-multiedit-next)
  (define-key evil-multiedit-insert-state-map (kbd "C-p") 'evil-multiedit-prev)
  (evil-ex-define-cmd "ie[dit]" 'evil-multiedit-ex-match))

(evil-define-state multiedit
  "`multiedit state' interfacing iedit mode."
  :tag " <ME> "
  :enable (normal)
  :cursor box
  :message "-- MULTIEDIT --"
  (if (eq evil-state 'multiedit)
      (progn
        (add-hook 'iedit-mode-end-hook 'evil-multiedit--cleanup)
        (advice-add 'evil-force-normal-state :before 'evil-multiedit-abort)
        (if (evil-replace-state-p) (call-interactively 'iedit-mode)))
    (remove-hook 'iedit-mode-end-hook 'evil-multiedit--cleanup)
    (advice-remove 'evil-force-normal-state 'evil-multiedit-abort)))

(evil-define-state multiedit-insert
  "Replace insert state in `iedit state'."
  :tag " <MEi> "
  :enable (insert)
  :cursor (bar . 2)
  :message "-- MULTIEDIT INSERT --")

(when evil-multiedit-dwim-motion-keys
  (let ((map evil-multiedit-insert-state-map))
    (define-key map (kbd "C-g") 'evil-multiedit-abort)
    (define-key map [escape]    'evil-multiedit-state))

  (let ((map evil-multiedit-state-map))
    (evil-redirect-digit-argument map "0" 'evil-multiedit--beginning-of-line)
    (define-key map "^"                   'evil-multiedit--beginning-of-line)
    (define-key map "$"                   'evil-multiedit--end-of-line)
    (define-key map "a"         'evil-multiedit--append)
    (define-key map "A"         'evil-multiedit--append-line)
    (define-key map "c"         'evil-multiedit--change)
    (define-key map "C"         'evil-multiedit--substitute)
    (define-key map "D"         'iedit-delete-occurrences)
    (define-key map "gg"        'iedit-goto-first-occurrence)
    (define-key map "G"         'iedit-goto-last-occurrence)
    (define-key map "i"         'evil-multiedit-insert-state)
    (define-key map "I"         'evil-multiedit--insert-line)
    (define-key map "o"         'evil-multiedit--open-below)
    (define-key map "O"         'evil-multiedit--open-above)
    (define-key map "p"         'evil-multiedit--paste-replace)
    (define-key map (kbd "C-g") 'evil-multiedit-abort)
    (define-key map [escape]    'evil-multiedit-abort)
    (define-key map "V"         'evil-multiedit--visual-line)
    (define-key map "za"        'iedit-toggle-unmatched-lines-visible)))

(provide 'evil-multiedit)
;;; evil-multiedit.el ends here
