// Paced raw-frame feeder: mimics a capture callback writing frames to a FIFO / unix socket / stdout.
#include <stdio.h>
#include <errno.h>
static long enob=0;
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <mach/mach_time.h>
static double now_ms(void){static mach_timebase_info_data_t tb;if(!tb.denom)mach_timebase_info(&tb);return (double)mach_absolute_time()*tb.numer/tb.denom/1e6;}
// usage: feeder file frame_size fps seconds target paced(0|1)   target: path | unix:path | -
int main(int c,char**v){
 if(c<7){fprintf(stderr,"args\n");return 2;}
 size_t fs=atol(v[2]);double fps=atof(v[3]);double secs=atof(v[4]);char*t=v[5];int paced=atoi(v[6]);
 int in=open(v[1],O_RDONLY);struct stat st;fstat(in,&st);uint8_t*m=mmap(0,st.st_size,PROT_READ,MAP_PRIVATE,in,0);
 madvise(m,st.st_size,MADV_WILLNEED);for(size_t i=0;i<(size_t)st.st_size;i+=16384)(void)*(volatile uint8_t*)(m+i);
 size_t nf=st.st_size/fs;int fd;
 if(!strcmp(t,"-"))fd=1;
 else if(!strncmp(t,"unix:",5)){fd=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un a={0};a.sun_family=AF_UNIX;strncpy(a.sun_path,t+5,sizeof a.sun_path-1);
   int sz=8*1024*1024;setsockopt(fd,SOL_SOCKET,SO_SNDBUF,&sz,sizeof sz);
   for(int i=0;i<500&&connect(fd,(void*)&a,sizeof a);i++)usleep(20000);}
 else fd=open(t,O_WRONLY);
 if(fd<0){perror("open");return 1;}
 long total=(long)(fps*secs),late=0,late2=0;long stall=getenv("STALL_MS")?atol(getenv("STALL_MS")):0;double start=now_ms(),maxb=0,sumb=0,period=1000/fps;
 for(long i=0;i<total;i++){
  double due=start+i*period;
  if(paced){double n;while((n=now_ms())<due){double r=due-n;if(r>1.5)usleep((r-1)*1000);}}
  double a=now_ms();uint8_t*p=m+(i%nf)*fs;size_t left=fs;
  int st=0;while(left){size_t chunk=left;if(stall&&i==100&&!st)chunk=left/2;ssize_t w=write(fd,p,chunk);if(stall&&i==100&&!st){st=1;usleep(stall*1000);}if(w<0){if(errno==ENOBUFS||errno==EAGAIN){enob++;usleep(500);if(st==1)st=2;continue;}perror("write");goto out;}p+=w;left-=w;}
  double b=now_ms()-a;sumb+=b;if(b>maxb)maxb=b;
  if(paced&&now_ms()>due+period){late++;if(i>fps*2)late2++;}
 }
 out:;double el=(now_ms()-start)/1000;close(fd);
 fprintf(stderr,"feeder frames=%ld elapsed=%.2fs rate=%.1f fps %.0f MB/s write_avg=%.2fms write_max=%.2fms late=%ld late_steady=%ld enobufs=%ld\n",total,el,total/el,total*fs/el/1e6,sumb/total,maxb,late,late2,enob);
 return 0;}
