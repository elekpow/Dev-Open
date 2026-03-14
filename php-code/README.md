# Developer
Developer (project)

**Тест транслита**

```
project/
├── index.php
├── functions/
│   └── translate.php
└── config/
    └── bootstrap.php
```


```
<?php
require_once __DIR__ . '/functions/translate.php';
// Или 
// require_once 'functions/translate.php';

$text = "Привет, мир!";
echo translit($text); // "Privet_mir_"
```