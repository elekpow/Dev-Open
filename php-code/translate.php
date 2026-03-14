<?php
function translit($str, $preserveSpaces = true)
{
    static $tr = null;
    static $cyrillicPattern = null;
    
    if ($tr === null) {
        $tr = [
            // Заглавные
            'А' => 'A', 'Б' => 'B', 'В' => 'V', 'Г' => 'G',
            'Д' => 'D', 'Е' => 'E', 'Ё' => 'E', 'Є' => 'E',
            'Ж' => 'J', 'З' => 'Z', 'И' => 'I', 'Й' => 'Y',
            'К' => 'K', 'Л' => 'L', 'М' => 'M', 'Н' => 'N',
            'О' => 'O', 'П' => 'P', 'Р' => 'R', 'С' => 'S',
            'Т' => 'T', 'У' => 'U', 'Ф' => 'F', 'Х' => 'H',
            'Ц' => 'TS', 'Ч' => 'CH', 'Ш' => 'SH', 'Щ' => 'SCH',
            'Ъ' => '', 'Ы' => 'YI', 'Ь' => '', 'Э' => 'E',
            'Ю' => 'YU', 'Я' => 'YA', 'Ї' => 'YI',
            // Строчные
            'а' => 'a', 'б' => 'b', 'в' => 'v', 'г' => 'g',
            'д' => 'd', 'е' => 'e', 'ё' => 'e', 'є' => 'e',
            'ж' => 'j', 'з' => 'z', 'и' => 'i', 'й' => 'y',
            'к' => 'k', 'л' => 'l', 'м' => 'm', 'н' => 'n',
            'о' => 'o', 'п' => 'p', 'р' => 'r', 'с' => 's',
            'т' => 't', 'у' => 'u', 'ф' => 'f', 'х' => 'h',
            'ц' => 'ts', 'ч' => 'ch', 'ш' => 'sh', 'щ' => 'sch',
            'ъ' => 'y', 'ы' => 'yi', 'ь' => '', 'э' => 'e',
            'ю' => 'yu', 'я' => 'ya', 'ї' => 'yi',
            // Спецсимволы
            '/' => '_'
        ];
        
        $cyrillicPattern = '/[А-Яа-яЁЄЇ]/u';
    }
    
    if (!preg_match($cyrillicPattern, $str)) {
        return $str;
    }
    
    $result = strtr($str, $tr);
    
    if ($preserveSpaces) {
        $result = preg_replace('/[^A-Za-z0-9_\-\s.]/', '', $result);
        $result = preg_replace('/\s+/', ' ', $result);
    } else {
        $result = str_replace(' ', '_', $result);
        $result = preg_replace('/[^A-Za-z0-9_\-.]/', '', $result);
    }
    
    return trim($result);
}