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

пример index.php

```
<?php
require_once __DIR__ . '/functions/translate.php';
// Или 
// require_once 'functions/translate.php';

$text = "Привет, мир!";
echo translit($text); // "Privet mir"
```