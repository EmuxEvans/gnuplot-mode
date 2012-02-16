;;
;; automated tests for gnuplot-mode context matching
;;

(require 'gnuplot-context)
(require 'ert)

(eval-when-compile
  (if (not (fboundp 'deftest))
      (defalias 'deftest 'ert-deftest)))


(defun gnuplot-tokenize-string (string)
  (with-temp-buffer
    (gnuplot-mode)
    (insert string)
    (goto-char (point-max))
    (gnuplot-tokenize)))
  
(defmacro with-gnuplot-tokens-from-string (binding &rest body)
  (declare (indent 1))
  `(with-temp-buffer
     (gnuplot-mode)
     (insert ,(cadr binding))
     (let ((,(car binding) (gnuplot-tokenize)))
       ,@body)))
	 
(defun gnuplot-simplify-tokens (tokens)
  (mapcar
   (lambda (token)
     (case (gnuplot-token-type token)
       (number
	(string-to-number (gnuplot-token-id token)))

       (string
	(gnuplot-token-id token))

       (end-of-input 'end-of-input)
       
       (otherwise
	(intern (gnuplot-token-id token)))))
       tokens))

;; compile a single pattern to vector form
(eval-when-compile
  (defun gnuplot-compile-pattern-1 (pattern)
    (vconcat (gnuplot-compile-pattern pattern) [(return)])))
 
;; match a string 
(defun gnuplot-match-string (string rule)
  (if (vectorp rule)
      (gnuplot-match-pattern
       rule (gnuplot-tokenize-string string) nil)
    (gnuplot-match-pattern
     gnuplot-compiled-grammar
     (gnuplot-tokenize-string string)
     nil rule)))

;; with-gensyms
(defmacro with-gensyms (symbols &rest forms)
  (declare (indent 1))
  `(let ,(mapcar
	  (lambda (sym)
	    `(,sym (make-symbol ,(symbol-name sym))))
	  symbols)
     ,@forms))

;; test-defining macro
(defmacro should-match (rule &rest pairs)
  (declare (indent 1))
  (with-gensyms (tokens result rest)
    `(let ((rule ,(if (symbolp rule)
		      `(quote ,rule)
		    (gnuplot-compile-pattern-1 rule))))
       ,@(mapcar
	  (lambda (pair)
	    (if (stringp pair)
		(setq pair (list pair)))

	    (let ((string (car pair))
		  (rest (cadr pair)))
	      (if (eq rest :none)		; Shouldn't match anything
		  `(should
		    (null
		     (gnuplot-match-string ,string rule)))
		`(should (equal
			  (gnuplot-simplify-tokens
			   (gnuplot-match-string ,string rule))
			  (append ,rest '(end-of-input)))))))
	  pairs))))


;; Number
(deftest gnuplot-number ()
  (should-match [number]
    ("123")
    (".05")
    ("1e7")))

;; name
(deftest gnuplot-name ()
  (should-match [name]
    ("foo")
    ("name_with_underscores")
    ("var123")))

;; string-constant

;; Note that the id of a string constant token includes the delimiters
(deftest gnuplot-string-constant ()
  (should-match [string]
    ("\"double quoted string\"")
    ("'single quoted'")))

;; sequence
(deftest gnuplot-sequence ()
  (should-match [number name]
    ("1.34 name garbage" '(garbage))
    ("2.718 xy")
    ("1e9 123 2.718281828459045" :none)))

;; either
(deftest gnuplot-either ()
  (should-match
      (either number name)
    ("1359, 349" '(\, 349))
    ("a_name . something" '(\. something))
    ("'quoted string constant' name" :none)))

;; many
(deftest gnuplot-many ()
  (should-match (many number)
    ("123 456 789")
    ("not a number" '(not a number))
    (".89 3.1415 foo" '(foo)))
  (should-match (many name)
    ("foo bar baz")
    ("tom dick harry 1.34" '(1.34))))

;; maybe
(deftest gnuplot-maybe ()
  (should-match (maybe name)
    ("foo bar baz" '(bar baz))
    ("1.23" '(1.23))
    ("'string' quux" '("'string'" quux))))

;; delimited list
(deftest gnuplot-delimited-list ()
  (should-match (delimited-list number ":")
    ("1:2:3")
    ("1e2:2.78")
    ("9")
    ("17:xy" '(: xy))
    ("nan" :none))
  (should-match (delimited-list name ",")
    ("foo,bar,baz")
    ("x,y")
    ("x"))
  (should-match (delimited-list number "-")
    ("1 - 2 - 3, garbage" '(\, garbage))
    ("x - 2 - 3" :none)
    ("1 - 2 - y" '(- y))))

;; keyword
(deftest gnuplot-keyword ()
  (should-match (either (kw ("w" . "ord"))
			(kw ("ot" . "her_word") "ow" "alt"))
    ("word")
    ("w")
    ("wo")
    ("wor")
    ("word thing" '(thing))
    ("o" :none)
    ("ot")
    ("oth")
    ("othx" :none)
    ("ow")
    ("alt")))

;; primary-expression
(deftest gnuplot-primary-expression ()
  (should-match primary-expression
    ("name")
    ("123")
    ("{3,5}")
    ("$23")
    ("\"string\"")
    ("5!! + 2" '(+ 2))
    ("5 ** 9")
    ("foo[3:5]")
    ("(1,2,3)")
    ("fun(3.14,x)")
    ("3!!**2 ," '(\,))
    ("," :none)
    ("]" :none)))

(deftest gnuplot-parenthesized-expression ()
  (should-match parenthesized-expression
    ("(sum = sum + $2, sum/2)")))

(deftest gnuplot-function-call ()
  (should-match function-call
    "abs(2)"
    "sin(pi*2)"
    "non_built_in(5+2)"
    "sprintf('%s*', columnheader(1))"
    "y(n)"))

;; expression
(deftest gnuplot-infix-expression ()
  (should-match expression
    ("-2")
    ("!~foo ^ bar , " '(\,))
    ("1+2%7 >= 9")
    ("f && g ? 1 + 2 : 5**2")
    ("t ? y(n) : n")
    ("f ? g ? 1 : 2 : 3 + x")
    ("f ? fun(1, 3+5 ** 7) : g > h ? pi:e : garbage"
     '(: garbage))))

;; assignments
(deftest gnuplot-assignment ()
  (should-match lhs
    ("x")
    ("long_identifier")
    ("1.9" :none)
    ("x(y)")
    ("fun(x_, y_) = " '(=))
    ("no_thunks()" '(\( \))))
  (should-match assignment
    ("x=2")
    ("x=y=3, garbage" '(\, garbage))
    ("f(a) = y(x) = 5")))

;; axis ranges
(deftest gnuplot-axis-range ()
  (should-match axis-range
     ("[-pi:pi]")
     ("[-1:1]")
     ("[t = -10 :30]")
     ("[ ]") 
     ("[-2:sin(5)*-8]")
     ("[:200]")
     ("[foo=:200]")
     ("[-pi:]")
     ("[bar=-pi:]")
     ("[baz=1:100*2:3/2]")
     ("[-pi:pi:0.2]")
     ("[\"1/6/93 12:00\":\"5/6/93 12:00\"]")))

;; iteration
(deftest gnuplot-iteration-spec ()
  (should-match iteration-spec
    ("for [x = 1:9]")
    ("for [y=-2*pi:2*pi:0.1]")
    ("for[1:2:3]" :none)))

;; plot expression, ignoring assignments
(deftest gnuplot-plot-expression ()
  (should-match plot-expression
    ("sin(x) + 2")
    ("a=5, foo")
    ("b=9 5+2")
    ("i=3, j=sin(x)+9 k = 1**2!! f(x) garbage" '(garbage))))

;; plot modifiers
(deftest gnuplot-plot-modifier ()
  (should-match plot-modifier
    ("lines 5 + 2")
    ("lw 9")

    ("titl 'string'[2:3]")
    ("notitle 'ignored'")
    ("notitle with lines" '(with lines))

    ("axes x1y2")
    ("axes" :none)
    ("axes 2 + 3" :none)))

(deftest gnuplot-with-modifier ()
  (should-match with-modifier
    ("with impulses")
    ("w points")
    ("with l")
    ("w i")
    ("with boxes")
    ("w lines")
    ("w errorbars")))

(deftest gnuplot-filledcurves ()
  (should-match filledcurves-style-clause
    ("filledcurves closed")
    ("filledcurves x1")
    ("filledcurves x2")
    ("filledcurves y1=0")
    ("filledcurves below y2=42")
    ("filledcurves xy=10,20")))

(deftest gnuplot-plot-command ()
  (should-match plot-command
    ("plot sin(x) with impulses")
      
     ("plot x w points, x**2")
     
     ("plot [ ] [-2:5] tan(x), 'data.1' with l")

     ("plot 'leastsq.dat' w i")
     
     ("plot 'exper.dat' w lines, 'exper.dat' notitle w errorbars")

     ("plot sin(x) with linesp lt 1 pt 3, cos(x) with linesp lt 1 pt 4")

     ("plot 'data' with points pointtype 3 pointsize 2")
     
     ("plot 'data' using 1:2:4 with points pt 5 pointsize variable")
     
     ("plot 'd1' t \"good\" w l lt 2 lw 3, 'd2' t \"bad\" w l lt 2 lw 1")

     ("plot x*x with filledcurve closed, 40 with filledcurve y1=10")
	
     ("plot x*x, (x>=-5 && x<=5 ? 40 : 1/0) with filledcurve y1=10 lt 8")))

;;; set cntrparam
(deftest gnuplot-cntrparam ()
  (should-match set-cntrparam-clause
    ("cntrparam bspline")
    ("cntrparam points 7")
    ("cntrparam order 10")
    ("cntrparam levels auto 5")
    ("cntrparam levels discrete .1,1/exp(1),.9")
    ("cntrparam levels incremental  0,1,4")
    ("cntrparam levels 10")
    ("cntrparam levels incremental 100,50")))
	     
	    

;;
;; test by parsing all the demos
;;

(defvar gnuplot-test-result-buffer "*gnuplot parse test results*")
(defvar gnuplot-test-count 0)
(defvar gnuplot-test-success-count 0)


(defun gnuplot-test-parse-all-demos ()
  (interactive)
  (let* ((bufname "*gnuplot parse test results*")
	 (gnuplot-test-result-buffer
	  (progn
	    (and bufname (get-buffer bufname)
		 (kill-buffer bufname))
	    (get-buffer-create bufname)))
	 (gnuplot-test-count 0)
	 (gnuplot-test-success-count 0)
	 (demo-dir "~/dev/gnuplot/demo/")
	 (demo-files (directory-files demo-dir t "^[^.].*\\.dem$"))
	 (n-files (length demo-files))
	 (n 0))
    
    (switch-to-buffer-other-window gnuplot-test-result-buffer)

    (catch 'done
      (dolist (fname demo-files)
	
	(with-temp-buffer
	  (insert-file-contents fname)
	  (gnuplot-mode)
	  (message "Testing on file %s of %s: %s..."
		   (incf n) n-files fname)
	  (condition-case err
	      (gnuplot-test-parse-buffer (current-buffer) fname)
	    (error
	     (with-current-buffer gnuplot-test-result-buffer
	       (insert (format "ERROR in %s: %s" fname err)))))
	  (message "Testing on file %s of %s: %s... done"
		   n n-files fname)
	  (with-current-buffer gnuplot-test-result-buffer
	    (goto-char (point-max))
	    (recenter)))))
    
    (with-current-buffer gnuplot-test-result-buffer
      (insert (format "\n\nPassed %s out of %s tests (%.2f%%)\n"
		      gnuplot-test-success-count
		      gnuplot-test-count
		      (* 100 (/ (+ gnuplot-test-success-count 0.0)
				gnuplot-test-count))))
      (compilation-mode))))

(defun gnuplot-test-parse-buffer (&optional buffer fname)
  (interactive nil)
  (let ((buffer (or buffer (current-buffer)))
	(fname (or fname (buffer-file-name))))
    (with-current-buffer buffer
      (goto-char (point-min))
      (while (not (eobp))
	(let ((ln (line-number-at-pos))
	      (tokens (progn
			(gnuplot-end-of-command)
			(gnuplot-tokenize))))
	  (when (> (length tokens) 1)
	    (let ((result
		   (gnuplot-simplify-tokens
		    (gnuplot-match-pattern
		     gnuplot-compiled-grammar
		     tokens nil))))
	      (incf gnuplot-test-count)
	      (if (eq (car result) 'end-of-input)
		  (incf gnuplot-test-success-count)
		(let ((cmd
		       (buffer-substring
			(gnuplot-point-at-beginning-of-command)
			(gnuplot-point-at-end-of-command))))
		  (with-current-buffer
		      (get-buffer-create gnuplot-test-result-buffer)
		    (insert
		     (format "FAILED at %s:%s\n\t%s\n" fname ln cmd))
		    (when result
		      (insert
		       (format "\tUNMATCHED TOKENS were: %s\n" result)))))))))
	(gnuplot-beginning-of-defun -1)))))

(add-to-list 'compilation-error-regexp-alist-alist
	     '(gnuplot-test-errors
	       "^FAILED at \\([^:]*\\):\\([0-9]*\\)" 1 2))

(add-to-list 'compilation-error-regexp-alist 'gnuplot-test-errors)

(provide 'gnuplot-test-context)
