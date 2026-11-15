#include "workaround.h"
my_sqlite3_destructor_type sqliteTransientAsDestructor(void) {
  return (my_sqlite3_destructor_type)-1;
}
