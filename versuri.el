;;; lyrics.el --- Playing with lyrics -*- lexical-binding: t -*-

(require 'cl-lib)
(require 'dash)
(require 'request)
(require 'elquery)
(require 's)
(require 'esqlite)

(defconst versuri--db-stream
  (let ((db (concat (xdg-config-home) "/versuri.db")))
    (esqlite-execute db
     (concat "CREATE TABLE IF NOT EXISTS lyrics ("
             "id     INTEGER PRIMARY KEY AUTOINCREMENT "
             "               UNIQUE "
             "               NOT NULL, "
             "artist TEXT    NOT NULL "
             "               COLLATE NOCASE, "
             "song   TEXT    NOT NULL "
             "               COLLATE NOCASE, "
             "lyrics TEXT    COLLATE NOCASE);"))
    (esqlite-stream-open db))
  "The storage place of all succesfully retrieved lyrics.")

(defun versuri--mappend (fn list)
  "Map `fn' on elements in `list' and append the resulted lists."
  (apply #'append (mapcar fn list)))

(defun versuri--db-read (query)
  "Call the `query' on the database and return the result."
  (esqlite-stream-read versuri--db-stream query))

(defun versuri--db-get-lyrics (artist song)
  "Retrieve the stored lyrics for `artist' and `song'."
  (aif (versuri--db-read
        (format "SELECT lyrics FROM lyrics WHERE artist=\"%s\" AND song=\"%s\""
                artist song))
      (car (car it))))

(defun versuri--db-search-lyrics-like (str)
  "Retrieve all entries that contain lyrics like `str'."
  (versuri--db-read
   (format "SELECT * from lyrics WHERE lyrics like '%% %s %%'" str)))

(defun versuri--db-save-lyrics (artist song lyrics)
  "Save the `lyrics' for `artist' and `song' in the database."
  (esqlite-stream-execute versuri--db-stream
   (format "INSERT INTO lyrics(artist,song,lyrics) VALUES(\"%s\", \"%s\", \"%s\")"
           artist song lyrics)))

(defun build-ivy-entryline (verse song str)
  ;; Get the whole line that matches the str
  (if-let ((full-line (cl-first
                       (s-match (format ".*%s.*" str) verse))))
      (list (format "%-15s | %-15s | %s"
                    (cadr song) (caddr song) full-line)
            (cadr song)
            (caddr song))))

(defun versuri--db-search-songs (str)
  "Search all stored lyrics that that match `str'. 
For each match, return the matched line together with the artist
and song name."
  (seq-uniq
   (seq-remove #'null
    (versuri--mappend (lambda (song)
                        (mapcar (lambda (verse)
                             (build-ivy-entryline verse song str))
                           (s-lines (cl-fourth song))))
                      (versuri--db-search-lyrics-like str)))))

(versuri--db-search-lyrics-like "free")

(defun lyrics-lyrics (query-str)
  "Select and return an entry from the lyrics db."
  (interactive "MSearch lyrics: ")
  (let (res)
    (ivy-read "Select Lyrics: "
            (versuri--db-search-songs query-str)
            :action (lambda (song)
                      (setf res (concat (cl-second song) " "
                                        (cl-third song)))))
    res))

;;;; Get the lyrics with elquery
;; elquery-read-string removes all newlines (issue on github created but no
;; response), so I've defined a new one, but this uses an internal elquery defun

(defun my-elquery-read-string (string)
  "Like the original elquery-read-string, but don't remove spaces."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert string)
    (let ((tree (libxml-parse-html-region (point-min) (point-max))))
      (thread-last tree
        (elquery--parse-libxml-tree nil)))))

(defconst lyrics-websites nil)

(cl-defstruct lyrics-website
  name template separator query)

(defun add-lyrics-website (name template separator query)
  (let ((new-website (make-lyrics-website
                      :name name
                      :template template         
                      :separator separator
                      :query query)))
    ;; Replace the entry if there is already a website with the same name.
    (aif (cl-position name lyrics-websites
                      :test (lambda (a b) (equal a b))
                      :key #'lyrics-website-name)
        (setf (nth it lyrics-websites) new-website)
      ;; Freshly add it, otherwise.
      (push new-website lyrics-websites))))

(defun lyrics-website (name)
  "Find a lyrics website from the list of known websites."
  (cl-find-if (lambda (w)
                (equal w name))
              lyrics-websites
              :key #'lyrics-website-name))

(add-lyrics-website "makeitpersonal"
  "https://makeitpersonal.co/lyrics?artist=${artist}&title=${song}"
  "-" "p")

(add-lyrics-website "genius"
  "https://genius.com/${artist}-${song}-lyrics"
  "-" "div.lyrics p")

(add-lyrics-website "songlyrics"
  "http://www.songlyrics.com/${artist}/${song}-lyrics/"
  "-" "p#songLyricsDiv")

(add-lyrics-website "metrolyrics"
  "http://www.metrolyrics.com/${song}-lyrics-${artist}.html"
  "-" "p.verse")

(add-lyrics-website "musixmatch"
  "https://www.musixmatch.com/lyrics/${artist}/${song}"
  "-" "p.mxm-lyrics__content span")

(add-lyrics-website "azlyrics"
  "https://www.azlyrics.com/lyrics/${artist}/${song}.html"
  "" "div.container.main-page div.row div:nth-child(2) div:nth-of-type(5)")

(defun build-url (website artist song)
  (let ((sep (lyrics-website-separator website)))
    (s-format (lyrics-website-template website)
              'aget
              `(("artist" . ,(s-replace " " sep artist))
                ("song"   . ,(s-replace " " sep song))))))

(defun request-website (website artist song callback)
  "Request the lyrics `website' for `artist' and `song'.
Call `callback' with the result or with nil in case of error."
  (let (resp)
    (request (build-url website artist song)
           :parser 'buffer-string
           :sync nil
           :success (cl-function
                     (lambda (&key data &allow-other-keys)
                       (funcall callback data)))
           :error (cl-function
                   (lambda (&key data &allow-other-keys)
                     (funcall callback nil)))))
  nil)

(defun parse-response (website html)
  (let* ((css (lyrics-website-query website))
         (parsed (elquery-$ css (my-elquery-read-string html)))
         (lyrics))
    ;; Some lyrics are split into multiple elements (musixmatch), otherwise, an
    ;; (elquery-text (car el)) would have been enough, which is basically what
    ;; happens if there is only one element, anyway.
    (mapcar (lambda (el)
         (let ((text (elquery-text el)))
           (setf lyrics (concat                         
                         (if (equal (lyrics-website-name website) "songlyrics")
                             ;; Songlyrics adds <br> elements after each line.
                             (s-replace "" "" text)
                           text)
                         "\n\n"
                         lyrics))))
       parsed)
    lyrics))

(cl-defun get-lyrics (artist song callback &optional (websites lyrics-websites))
  "By default, the function starts with all the known
websites. To avoid getting banned, I take a random website on
every request. If the lyrics is not found on that website, repeat
the call with the remaining websites."
  (if-let (lyrics (db-get-lyrics artist song))
      (funcall callback lyrics)
    (when-let (website (nth (random (length websites))
                            lyrics-websites))        
        (request-website website artist song
          (lambda (resp)
            (if (and resp
                     ;; makeitpersonal
                     (not (s-contains? "Sorry, We don't have lyrics" resp)))
                ;; Positive response
                (when-let (lyrics (parse-response website resp))
                  (versuri--db-save-lyrics artist song lyrics)                  
                  (get-lyrics artist song callback))
              ;; Lyrics not found, try another website.
              (get-lyrics artist song callback
                          (-remove-item website lyrics-websites))))))))

(defun display-lyrics-in-buffer (artist song)
  (get-lyrics artist song
    (lambda (lyrics)
      (let ((name (format "%s - %s | lyrics" artist song)))
        (aif (get-buffer name)
            (switch-to-buffer it)
          (let ((b (generate-new-buffer name)))
            (with-current-buffer b
              (insert (format "%s - %s\n\n" artist song))
              (insert lyrics)
              (read-only-mode)
              (local-set-key (kbd "q") 'kill-current-buffer))
            (switch-to-buffer b)))))))

(defun save-lyrics (artist song)
  (get-lyrics artist song #'ignore))

(defun bulk-request-sync (songs max-timeout)
  (dolist (song songs)
    (save-lyrics (car song) (cadr song))
    (sleep-for (random max-timeout))))


