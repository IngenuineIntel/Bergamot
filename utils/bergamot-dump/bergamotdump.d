

void main() {
  import core.thread : Thread;
  import core.sync.event : Event;
  import core.sync.mutex : Mutex;
  import core.time : MonoTime;
  import core.time;
  import std.socket;
  import std.stdio;

  class Server {
    
    // the port to listen on
    private int port;
   
    // the internal socket
    private auto sock;

    // a mutex for everything other than the kill switch
    private Mutex m;

    // a mutex for the kill switch
    private Mutex ks_m;
    private bool kill_switch = false;
    
    // the frequency for the thread to operate at
    private int thread_freq;

    private void thread_inter() {
      
      MonoTime start_ts;
      MonoTime end_ts;
      Duration sleep_dur;

      // locking sock for initialization
      m.lock_nothrow();

      sock = new TcpSocket();
      sock.blocking = true;
      sock.bind(new InternetAddress(port));

      // unlocking sock
      m.unlock_nothrow();

      start_ts = MonoTime.currTime;

      ks_m.lock_nothrow(); 
      while (kill_switch == false)
      {

        ks_m.unlock_nothrow();
      
        // lock sock
        m.lock_nothrow();
        
        // TODO

        // unlock sock
        m.unlock_nothrow();


        end_ts = MonoTime.currTime;

        // calculate sleep time against execution time to maintain the correct
        // frequency
        sleep_dur = start_ts - end_ts;
        sleep_dur += seconds(1 / thread_freq);

        Thread.sleep(sleep_dur);

        start_ts = MonoTime.currTime;

        // relocking the kill switch mutex for the condition in while
        ks_m.lock_nothrow();
      }

    }

    this(int port) {
      
      // initialize mutexes
      //m = new shared Mutex();
      //ks_m = new shared Mutex();

    }
  }
}
