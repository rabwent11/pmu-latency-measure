#ifndef FLASH_PERSISTENT_SIZE
#define FLASH_PERSISTENT_SIZE 15
#endif

#ifndef FLASH_PERSISTENT_BASE
#define FLASH_PERSISTENT_BASE 65536
#endif

#ifndef FLASH_PERSISTENT_SEGMENT_SIZE
#define FLASH_PERSISTENT_SEGMENT_SIZE (2*FLASH_SPI_SECTOR_SIZE)
#endif

#define FLASH_PERSISTENT_SECTOR_SIZE FLASH_SPI_SECTOR_SIZE

#if ((FLASH_PERSISTENT_SIZE & (FLASH_PERSISTENT_SIZE+1)) != 0)
#error "FLASH_PERSISTENT_SIZE should be a power of 2 minus one"
#endif

#if ((FLASH_PERSISTENT_SEGMENT_SIZE & (FLASH_PERSISTENT_SEGMENT_SIZE-1)) != 0)
#error "FLASH_PERSISTENT_SEGMENT_SIZE should be a power of 2"
#endif

#if ((FLASH_PERSISTENT_SECTOR_SIZE & (FLASH_PERSISTENT_SECTOR_SIZE-1)) != 0)
#error "FLASH_PERSISTENT_SEGMENT_SIZE should be a power of 2"
#endif

#if (FLASH_PERSISTENT_SECTOR_SIZE < 4096)
#error "FLASH_PERSISTENT_SECTOR_SIZE should not be less than 4096"
#endif

#if (FLASH_PERSISTENT_SEGMENT_SIZE < FLASH_PERSISTENT_SECTOR_SIZE * 2)
#error "FLASH_PERSISTENT_SEGMENT_SIZE should not be less than 2 * FLASH_PERSISTENT_SECTOR_SIZE"
#endif
